//! Codex/Claude가 로컬에 남긴 JSONL을 도크용 **세션 요약**으로 낮춘다.
//!
//! 이 모듈은 파일을 찾거나 열지 않는다. provider 포맷에서 사용자 세션인지와 표시 가능한 최소 metadata를
//! 추출하는 L2 경계라, 개인 transcript를 UI/worker/테스트가 각자 다르게 해석하지 않게 한다.

const std = @import("std");

pub const Provider = enum {
    claude,
    codex,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .codex => "Codex",
        };
    }
};

pub const max_title_bytes: usize = 120;
pub const max_summary_bytes: usize = 240;
pub const max_cwd_bytes: usize = 1024;

/// Scanner가 파일 identity/mtime을 붙이기 전의 provider-neutral 요약.
/// 모든 텍스트는 allocator-owned이고 `deinit`이 단일 회수점이다.
pub const Parsed = struct {
    provider: Provider,
    session_id: []u8,
    title: []u8,
    summary: []u8,
    cwd: []u8,
    /// Set only by the worker after this provider value resolves to a local
    /// directory.  Raw JSONL cwd text must never be used for scoped
    /// containment because it can be deleted, remote, or a lexical alias.
    cwd_canonical: bool = false,
    model: []u8,
    message_count: u32,
    verified_user: bool,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.free(self.summary);
        allocator.free(self.cwd);
        allocator.free(self.model);
        self.* = undefined;
    }

    pub fn clone(self: *const Parsed, allocator: std.mem.Allocator) !Parsed {
        return duplicateParsed(allocator, self.provider, self.session_id, self.title, self.summary, self.cwd, self.cwd_canonical, self.model, self.message_count, self.verified_user);
    }
};

/// Claude 직속 transcript 혹은 Codex rollout 한 파일의 bounded bytes를 분석한다.
/// `null`은 손상/worker/legacy-unknown/무식별 세션으로, 호출자가 목록에 넣지 않아야 한다.
/// 한 파일을 **줄 단위로** 소비해 요약을 만드는 파서.
///
/// 호출자가 파일 전체를 메모리에 올릴 필요가 없다는 것이 요점이다. 예전에는 스캐너가
/// `allocator.alloc(u8, size)`로 파일을 통째로 읽어 넘겼고(피크 463 MB 실측), 그 할당을 방어하려고
/// 파일당·refresh당 read cap이 존재했다. 파서 자체는 처음부터 `splitScalar`로 줄을 훑고 있었으므로
/// 전체 버퍼를 요구한 것은 파서가 아니라 호출자였다 — 이 인터페이스가 그 요구를 없앤다.
///
/// 상태는 고정 버퍼뿐이라 파일 크기와 무관하게 일정하다(약 3 KB).
pub const Parser = struct {
    allocator: std.mem.Allocator,
    provider: Provider,

    session_id_buf: [max_cwd_bytes]u8 = undefined,
    cwd_buf: [max_cwd_bytes]u8 = undefined,
    model_buf: [max_title_bytes]u8 = undefined,
    title_buf: [max_title_bytes]u8 = undefined,
    first_user_buf: [max_summary_bytes]u8 = undefined,
    last_user_buf: [max_summary_bytes]u8 = undefined,
    last_assistant_buf: [max_summary_bytes]u8 = undefined,

    session_id: []const u8 = "",
    cwd: []const u8 = "",
    model: []const u8 = "",
    title: []const u8 = "",
    first_user: []const u8 = "",
    last_user: []const u8 = "",
    last_assistant: []const u8 = "",
    count: u32 = 0,

    // Codex 전용 판정 상태. `is_user`는 `session_meta`를 만날 때마다 갱신되며 **마지막 값이 이긴다**
    // (docs/agent-session-list.md §3.1).
    saw_meta: bool = false,
    is_user: bool = false,
    /// 이 파일에서 `user` 신호를 한 번이라도 봤는가. 조기 중단 판정에만 쓴다 — 한 번 본 뒤에는 뒤에
    /// 오는 worker 메타로 뒤집어 중단하지 않는다.
    saw_user_signal: bool = false,

    pub fn init(allocator: std.mem.Allocator, provider: Provider) Parser {
        return .{ .allocator = allocator, .provider = provider };
    }

    /// 줄 하나를 소비한다. 손상된 줄은 그 줄만 버리고 record를 추측해 만들지 않는다.
    pub fn consumeLine(self: *Parser, line: []const u8) void {
        switch (self.provider) {
            .claude => self.consumeClaudeLine(line),
            .codex => self.consumeCodexLine(line),
        }
    }

    /// Codex worker로 **확정**됐는가. 확정은 "앞부분을 충분히 읽고도 `user` 신호를 한 번도 못 봤을 때"만
    /// 성립하므로, 호출자가 그 경계(§4-3)에서 한 번만 묻는다. 그 전에 물으면 `첫=subagent 마지막=user`인
    /// 정상 세션(실측 256개 중 118개)을 잘못 버린다.
    pub fn isWorkerSoFar(self: *const Parser) bool {
        return self.provider == .codex and self.saw_meta and !self.saw_user_signal;
    }

    pub fn finish(self: *Parser) !?Parsed {
        return switch (self.provider) {
            .claude => self.finishClaude(),
            .codex => self.finishCodex(),
        };
    }

    fn consumeClaudeLine(self: *Parser, line: []const u8) void {
        const root = parseObject(self.allocator, line) orelse return;
        defer root.deinit();
        const obj = root.value.object;
        if (string(obj.get("sessionId"))) |value| self.session_id = copyInto(&self.session_id_buf, value);
        if (string(obj.get("cwd"))) |value| self.cwd = copyInto(&self.cwd_buf, value);
        if (string(obj.get("custom-title")) orelse string(obj.get("customTitle")) orelse string(obj.get("title"))) |value| {
            if (value.len > 0) self.title = copyInto(&self.title_buf, value);
        }
        const kind = string(obj.get("type")) orelse "";
        if (std.mem.eql(u8, kind, "ai-title")) {
            if (string(obj.get("aiTitle")) orelse string(obj.get("title")) orelse nestedString(obj, "message", "text")) |value| {
                if (value.len > 0) self.title = copyInto(&self.title_buf, value);
            }
        }
        const message = object(obj.get("message"));
        // Current Claude Code writes the invoked model on assistant
        // `message.model`; a top-level model is only a compatibility fallback.
        if ((if (message) |m| string(m.get("model")) else null) orelse string(obj.get("model"))) |value|
            self.model = copyInto(&self.model_buf, value);
        const role = if (message) |m| string(m.get("role")) orelse "" else string(obj.get("role")) orelse "";
        const text = if (message) |m| string(m.get("text")) orelse contentText(m) else string(obj.get("text"));
        if (text) |value| {
            if (value.len == 0) return;
            self.count +|= 1;
            if (std.mem.eql(u8, role, "user")) {
                if (self.first_user.len == 0) self.first_user = copyInto(&self.first_user_buf, value);
                self.last_user = copyInto(&self.last_user_buf, value);
            } else if (std.mem.eql(u8, role, "assistant")) self.last_assistant = copyInto(&self.last_assistant_buf, value);
        }
    }

    fn consumeCodexLine(self: *Parser, line: []const u8) void {
        const root = parseObject(self.allocator, line) orelse return;
        defer root.deinit();
        const obj = root.value.object;
        const kind = string(obj.get("type")) orelse "";
        const payload = object(obj.get("payload"));
        if (std.mem.eql(u8, kind, "session_meta")) {
            const p = payload orelse return;
            self.saw_meta = true;
            if (string(p.get("id"))) |value| self.session_id = copyInto(&self.session_id_buf, value);
            if (string(p.get("cwd"))) |value| self.cwd = copyInto(&self.cwd_buf, value);
            self.is_user = codexIsUserThread(p);
            if (self.is_user) self.saw_user_signal = true;
            return;
        }
        if (std.mem.eql(u8, kind, "turn_context")) {
            if (payload) |p| {
                if (string(p.get("model"))) |value| self.model = copyInto(&self.model_buf, value);
            }
            return;
        }
        if (!std.mem.eql(u8, kind, "event_msg")) return;
        const p = payload orelse return;
        const event_kind = string(p.get("type")) orelse "";
        const text = string(p.get("message")) orelse return;
        if (text.len == 0) return;
        if (std.mem.eql(u8, event_kind, "user_message")) {
            const clean = stripCodexPrefix(text);
            if (clean.len == 0) return;
            self.count +|= 1;
            if (self.first_user.len == 0) self.first_user = copyInto(&self.first_user_buf, clean);
            self.last_user = copyInto(&self.last_user_buf, clean);
        } else if (std.mem.eql(u8, event_kind, "agent_message")) {
            self.count +|= 1;
            self.last_assistant = copyInto(&self.last_assistant_buf, text);
        }
    }

    fn finishClaude(self: *Parser) !?Parsed {
        if (self.session_id.len == 0) return null;
        const display_title = if (self.title.len > 0) self.title else if (self.first_user.len > 0) self.first_user else "제목 없는 세션";
        const summary = if (self.last_user.len > 0) self.last_user else self.last_assistant;
        return try duplicateParsed(self.allocator, .claude, self.session_id, display_title, summary, self.cwd, false, self.model, self.count, true);
    }

    fn finishCodex(self: *Parser) !?Parsed {
        if (!self.saw_meta or !self.is_user or self.session_id.len == 0) return null;
        const title = if (self.first_user.len > 0) self.first_user else "제목 없는 세션";
        const summary = if (self.last_user.len > 0) self.last_user else self.last_assistant;
        return try duplicateParsed(self.allocator, .codex, self.session_id, title, summary, self.cwd, false, self.model, self.count, true);
    }
};

/// 버퍼 하나를 통째로 받는 진입점. `Parser`를 줄 단위로 돌린 것과 **결과가 같다** — fixture·테스트와
/// 부분 입력 비교가 이 등가성에 의존한다.
pub fn parse(allocator: std.mem.Allocator, provider: Provider, bytes: []const u8) !?Parsed {
    var parser = Parser.init(allocator, provider);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| parser.consumeLine(line);
    return parser.finish();
}

fn duplicateParsed(allocator: std.mem.Allocator, provider: Provider, session_id: []const u8, title: []const u8, summary: []const u8, cwd: []const u8, cwd_canonical: bool, model: []const u8, message_count: u32, verified_user: bool) !Parsed {
    const out = Parsed{
        .provider = provider,
        .session_id = try allocator.dupe(u8, session_id),
        .title = try displayCopy(allocator, title, max_title_bytes),
        .summary = try displayCopy(allocator, summary, max_summary_bytes),
        .cwd = try displayCopy(allocator, cwd, max_cwd_bytes),
        .cwd_canonical = cwd_canonical,
        .model = try displayCopy(allocator, model, max_title_bytes),
        .message_count = message_count,
        .verified_user = verified_user,
    };
    return out;
}

fn displayCopy(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    var cleaned: [max_cwd_bytes]u8 = undefined;
    var n: usize = 0;
    for (text) |byte| {
        if (n == max_len or n == cleaned.len) break;
        const normalized = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        cleaned[n] = normalized;
        n += 1;
    }
    return allocator.dupe(u8, std.mem.trim(u8, cleaned[0..n], " \t\r\n"));
}

fn copyInto(buf: []u8, text: []const u8) []const u8 {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

fn parseObject(allocator: std.mem.Allocator, line: []const u8) ?std.json.Parsed(std.json.Value) {
    if (line.len < 2 or line[0] != '{') return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

fn object(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn nestedString(obj: std.json.ObjectMap, key: []const u8, nested: []const u8) ?[]const u8 {
    const child = object(obj.get(key)) orelse return null;
    return string(child.get(nested));
}

fn contentText(obj: std.json.ObjectMap) ?[]const u8 {
    const content = obj.get("content") orelse return null;
    return switch (content) {
        .string => |text| text,
        .array => |items| for (items.items) |item| {
            const part = object(item) orelse continue;
            if (string(part.get("text"))) |text| break text;
        } else null,
        else => null,
    };
}

fn stripCodexPrefix(text: []const u8) []const u8 {
    const marker = "## My request for Codex:";
    const start = if (std.mem.indexOf(u8, text, marker)) |index| text[index + marker.len ..] else text;
    return std.mem.trim(u8, start, " \t\r\n");
}

/// Codex `session_meta.payload` 하나에서 "사용자 세션인가"를 판정한다(docs/agent-session-list.md §3.1).
///
/// 신호가 없으면 **포함**한다. `thread_source`는 최근 Codex가 추가한 필드라, 없다고 버리면 구버전에 남은
/// 실제 사용자 대화가 통째로 사라진다(실측: 개발자 머신에서 67개가 전부 사용자 대화였고 모두
/// `payload.id`를 갖고 있었다). 목록에서 조용히 사라진 세션은 사용자가 알아챌 방법이 없지만, worker가
/// 섞이면 보고 무시할 수 있다 — 그래서 기본을 "제외"가 아니라 "포함"으로 둔다.
///
/// 호출자는 `session_meta`를 만날 때마다 이 값을 갱신한다. **한 파일에 `session_meta`가 여러 번 나오고**
/// (실측 256개 중 123개), 그중 118개는 첫 메타가 `subagent`지만 마지막이 `user`인 정상 세션이다.
/// 따라서 판정은 **마지막으로 관측한 메타**가 이긴다.
fn codexIsUserThread(payload: std.json.ObjectMap) bool {
    if (string(payload.get("thread_source")) orelse string(payload.get("threadSource"))) |value| {
        return std.mem.eql(u8, value, "user");
    }
    if (object(payload.get("source"))) |source| return object(source.get("subagent")) == null;
    return true;
}

// 스트리밍 소비가 **전체 버퍼 파싱과 같은 결과**를 내는가. 스캐너가 파일을 64 KiB 청크로 읽어
// `consumeLine`에 넘기므로, 줄이 청크 경계에 걸치거나 마지막 줄에 개행이 없어도 값을 잃으면 안 된다.
// 이 등가성이 깨지면 목록이 조용히 틀린 요약을 보인다.
test "Parser 스트리밍: 어떤 청크 경계로 잘라도 전체 파싱과 같다" {
    const a = std.testing.allocator;
    const fixtures = [_]struct { provider: Provider, bytes: []const u8 }{
        .{ .provider = .claude, .bytes =
        \\{"sessionId":"c-1","cwd":"/repo","type":"user","message":{"role":"user","content":[{"type":"text","text":"첫 요청"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"m-old","content":[{"type":"text","text":"응답1"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"m-new","content":[{"type":"text","text":"응답2"}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"마지막 요청"}]}}
        },
        .{ .provider = .codex, .bytes =
        \\{"type":"session_meta","payload":{"id":"x-1","thread_source":"subagent"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"worker turn"}}
        \\{"type":"session_meta","payload":{"id":"x-1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"model":"gpt-x"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"사용자 요청"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"응답"}}
        },
    };

    for (fixtures) |fx| {
        var whole = (try parse(a, fx.provider, fx.bytes)).?;
        defer whole.deinit(a);

        // 1바이트부터 전체 길이까지 모든 청크 크기로 잘라 넣어도 결과가 같아야 한다. 줄 중간, 개행
        // 직전/직후 등 모든 경계가 이 스윕에 포함된다.
        var chunk: usize = 1;
        while (chunk <= fx.bytes.len) : (chunk += 1) {
            var parser = Parser.init(a, fx.provider);
            var pending: std.ArrayList(u8) = .empty;
            defer pending.deinit(a);
            var offset: usize = 0;
            while (offset < fx.bytes.len) {
                const end = @min(offset + chunk, fx.bytes.len);
                var rest: []const u8 = fx.bytes[offset..end];
                offset = end;
                while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                    const piece = rest[0..nl];
                    rest = rest[nl + 1 ..];
                    if (pending.items.len == 0) {
                        parser.consumeLine(piece);
                    } else {
                        try pending.appendSlice(a, piece);
                        parser.consumeLine(pending.items);
                        pending.clearRetainingCapacity();
                    }
                }
                if (rest.len > 0) try pending.appendSlice(a, rest);
            }
            if (pending.items.len > 0) parser.consumeLine(pending.items); // 개행 없는 마지막 줄
            var streamed = (try parser.finish()).?;
            defer streamed.deinit(a);

            try std.testing.expectEqualStrings(whole.session_id, streamed.session_id);
            try std.testing.expectEqualStrings(whole.title, streamed.title);
            try std.testing.expectEqualStrings(whole.summary, streamed.summary);
            try std.testing.expectEqualStrings(whole.cwd, streamed.cwd);
            try std.testing.expectEqualStrings(whole.model, streamed.model);
            try std.testing.expectEqual(whole.message_count, streamed.message_count);
        }
    }
}

// Codex worker 조기 중단 판정. 스캐너는 앞부분을 충분히 읽은 **뒤 한 번만** 이 값을 묻는다 — 그 전에
// 물으면 `첫=subagent 마지막=user`인 정상 세션(실측 256개 중 118개)을 잘못 버린다.
test "Parser: worker 확정은 user 신호를 한 번도 못 봤을 때만" {
    const a = std.testing.allocator;

    // 첫 메타가 subagent여도, user 신호를 본 뒤에는 worker로 확정하지 않는다.
    var flip = Parser.init(a, .codex);
    flip.consumeLine(
        \\{"type":"session_meta","payload":{"id":"f","thread_source":"subagent"}}
    );
    try std.testing.expect(flip.isWorkerSoFar()); // 아직 user를 못 봤다
    flip.consumeLine(
        \\{"type":"session_meta","payload":{"id":"f","thread_source":"user"}}
    );
    try std.testing.expect(!flip.isWorkerSoFar()); // user를 봤으니 확정하지 않는다
    // 뒤에 다시 worker 메타가 와도 뒤집어 중단하지 않는다(읽기를 끝까지 하고 finish가 판정한다).
    flip.consumeLine(
        \\{"type":"session_meta","payload":{"id":"f","thread_source":"subagent"}}
    );
    try std.testing.expect(!flip.isWorkerSoFar());

    // 메타를 아직 못 본 파일은 worker로 확정하지 않는다 — 판정 불가는 제외가 아니다.
    var none = Parser.init(a, .codex);
    none.consumeLine(
        \\{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    );
    try std.testing.expect(!none.isWorkerSoFar());

    // Claude는 이 판정의 대상이 아니다.
    var claude = Parser.init(a, .claude);
    claude.consumeLine(
        \\{"sessionId":"c","type":"user","message":{"role":"user","text":"x"}}
    );
    try std.testing.expect(!claude.isWorkerSoFar());
}

test "Codex user session parses and worker is rejected" {
    const user =
        \\{"type":"session_meta","payload":{"id":"codex-1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"model":"gpt-test"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"## My request for Codex: fix it"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}
    ;
    var parsed = (try parse(std.testing.allocator, .codex, user)).?;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("codex-1", parsed.session_id);
    try std.testing.expectEqualStrings("fix it", parsed.title);
    try std.testing.expectEqual(@as(u32, 2), parsed.message_count);
    try std.testing.expect(!parsed.cwd_canonical); // worker boundary owns filesystem canonicalization

    const worker = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"thread_source\":\"subagent\"}}\n";
    try std.testing.expect((try parse(std.testing.allocator, .codex, worker)) == null);
}

test "Codex worker 판정: 신호 순서와 마지막 session_meta 우선" {
    const a = std.testing.allocator;

    // ① thread_source가 있으면 그 값이 이긴다.
    const explicit_worker = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"thread_source\":\"subagent\"}}\n";
    try std.testing.expect((try parse(a, .codex, explicit_worker)) == null);

    // ② 필드가 없으면 2차 신호 source.subagent로 가른다.
    const source_worker =
        \\{"type":"session_meta","payload":{"id":"x","source":{"subagent":{"name":"w"}}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    ;
    try std.testing.expect((try parse(a, .codex, source_worker)) == null);

    // ③ 둘 다 없으면 **사용자 세션으로 포함**한다. 구버전 Codex가 여기 해당하며, 예전에는 통째로
    //    버려졌다(실측 67개 소실). 목록에서 조용히 사라지는 쪽이 worker가 섞이는 쪽보다 나쁘다.
    const legacy =
        \\{"type":"session_meta","payload":{"id":"legacy-1","cwd":"/repo"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"오래된 요청"}}
    ;
    var legacy_parsed = (try parse(a, .codex, legacy)).?;
    defer legacy_parsed.deinit(a);
    try std.testing.expectEqualStrings("legacy-1", legacy_parsed.session_id);
    try std.testing.expectEqualStrings("오래된 요청", legacy_parsed.title);

    // ④ source는 있지만 subagent 키가 없으면 worker가 아니다.
    const source_not_worker =
        \\{"type":"session_meta","payload":{"id":"s1","source":{"cli":{}}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
    ;
    var s1 = (try parse(a, .codex, source_not_worker)).?;
    defer s1.deinit(a);
    try std.testing.expectEqualStrings("s1", s1.session_id);

    // ⑤ **마지막 session_meta가 이긴다.** 한 파일에 메타가 여러 번 나오고 첫 것이 subagent, 마지막이
    //    user인 경우가 실측 256개 중 118개다. 첫 메타로 확정하면 그 118개가 전부 사라진다.
    const flip =
        \\{"type":"session_meta","payload":{"id":"f1","thread_source":"subagent"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"worker turn"}}
        \\{"type":"session_meta","payload":{"id":"f1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"사용자 요청"}}
    ;
    var flipped = (try parse(a, .codex, flip)).?;
    defer flipped.deinit(a);
    try std.testing.expectEqualStrings("f1", flipped.session_id);
    try std.testing.expectEqualStrings("사용자 요청", flipped.summary);

    // ⑥ 반대 방향도 마지막이 이긴다 — user로 시작해 worker로 끝나면 제외다.
    const flip_back =
        \\{"type":"session_meta","payload":{"id":"f2","thread_source":"user"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
        \\{"type":"session_meta","payload":{"id":"f2","thread_source":"subagent"}}
    ;
    try std.testing.expect((try parse(a, .codex, flip_back)) == null);

    // ⑦ session_meta가 아예 없으면 식별 근거가 없어 제외한다(포함 기본값의 예외).
    const no_meta = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"고아\"}}\n";
    try std.testing.expect((try parse(a, .codex, no_meta)) == null);
}

test "Claude 파서: content 배열·모델 변경·손상 줄·개행 없는 마지막 줄" {
    const a = std.testing.allocator;

    // message.text가 없고 content 배열만 있는 형태(실제 Claude transcript의 주 형태).
    // 손상된 줄은 그 줄만 버리고 나머지는 계속 읽는다 — record를 추측해 만들지 않는다.
    // 모델은 마지막으로 본 assistant message.model이 이긴다(세션 중 모델을 바꾸면 최신이 표시돼야 한다).
    // 마지막 줄에 개행이 없어도 값을 잃지 않는다.
    const fixture =
        \\{"sessionId":"c-1","cwd":"/repo","type":"user","message":{"role":"user","content":[{"type":"text","text":"첫 요청"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"model-old","content":[{"type":"text","text":"응답1"}]}}
        \\이건 JSON이 아니다
        \\{"type":"assistant","message":{"role":"assistant","model":"model-new","content":[{"type":"text","text":"응답2"}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"마지막 요청"}]}}
    ;
    var parsed = (try parse(a, .claude, fixture)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("c-1", parsed.session_id);
    try std.testing.expectEqualStrings("첫 요청", parsed.title); // 명시 제목이 없으면 첫 사용자 메시지
    try std.testing.expectEqualStrings("마지막 요청", parsed.summary);
    try std.testing.expectEqualStrings("model-new", parsed.model);
    try std.testing.expectEqual(@as(u32, 4), parsed.message_count); // 손상 줄은 세지 않는다

    // sessionId가 없으면 안정 identity가 없으므로 제외한다.
    const no_id = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"text\":\"x\"}}\n";
    try std.testing.expect((try parse(a, .claude, no_id)) == null);
}

test "Claude title prefers explicit title then latest user summary" {
    const fixture =
        \\{"sessionId":"claude-1","cwd":"/repo","type":"ai-title","aiTitle":"명시 제목"}
        \\{"type":"user","message":{"role":"user","text":"첫 요청"}}
        \\{"type":"assistant","message":{"role":"assistant","model":"claude-test","text":"응답"}}
        \\{"type":"user","message":{"role":"user","text":"마지막 요청"}}
    ;
    var parsed = (try parse(std.testing.allocator, .claude, fixture)).?;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("명시 제목", parsed.title);
    try std.testing.expectEqualStrings("마지막 요청", parsed.summary);
    try std.testing.expectEqualStrings("claude-test", parsed.model);
}
