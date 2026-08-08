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
    /// transcript가 스스로 말하는 마지막 활동 시각(Unix epoch 나노초). 0이면 이 파일에서 하나도 읽지
    /// 못했다는 뜻이고, 호출자가 파일 mtime으로 폴백한다.
    ///
    /// mtime은 대화 외의 이유(복사·도구의 메타 갱신·백업 복원)로도 밀린다. 실측(2026-08-08, 로컬 이력
    /// 362개)에서 mtime으로 정렬하면 257개(70%)가 제자리가 아니었고 Claude 쪽 최대 차이는 144시간이었다.
    last_activity_ns: i96 = 0,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.free(self.summary);
        allocator.free(self.cwd);
        allocator.free(self.model);
        self.* = undefined;
    }

    pub fn clone(self: *const Parsed, allocator: std.mem.Allocator) !Parsed {
        var out = try duplicateParsed(allocator, self.provider, self.session_id, self.title, self.summary, self.cwd, self.cwd_canonical, self.model, self.message_count, self.verified_user);
        // `duplicateParsed`는 **인자로 받은 것만** 세운다. Parsed에 스칼라를 더하면 여기에도 더해야
        // 한다 — 캐시 히트와 부분 진행 발행이 모두 이 clone을 지나므로, 빠뜨리면 그 값만 조용히 0이
        // 된다. 아래 "clone은 모든 필드를 보존한다" 테스트가 comptime으로 전 필드를 훑어 막는다.
        out.last_activity_ns = self.last_activity_ns;
        return out;
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
    /// 이 파일에서 본 **가장 늦은** timestamp. 마지막으로 본 값이 아니라 최댓값을 쓴다 — 줄 순서가
    /// 시간 순이라는 보장이 없고(요약·메타 줄이 뒤에 붙는 형식이 있다), "마지막 활동"은 순서가 아니라
    /// 시각으로 정해야 한다.
    last_activity_ns: i96 = 0,

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

    /// 두 provider 모두 각 줄 최상위에 `timestamp`를 싣는다. provider별 소비 함수가 이미 JSON을 열었으므로
    /// 거기서 이 값을 함께 넘긴다 — 정렬 하나 때문에 같은 줄을 두 번 파싱하지 않는다.
    fn observeTimestamp(self: *Parser, obj: std.json.ObjectMap) void {
        const text = string(obj.get("timestamp")) orelse return;
        const ns = parseRfc3339Utc(text) orelse return;
        if (ns > self.last_activity_ns) self.last_activity_ns = ns;
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
        self.observeTimestamp(obj);
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
        self.observeTimestamp(obj);
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
        var parsed = try duplicateParsed(self.allocator, .claude, self.session_id, display_title, summary, self.cwd, false, self.model, self.count, true);
        parsed.last_activity_ns = self.last_activity_ns;
        return parsed;
    }

    fn finishCodex(self: *Parser) !?Parsed {
        if (!self.saw_meta or !self.is_user or self.session_id.len == 0) return null;
        const title = if (self.first_user.len > 0) self.first_user else "제목 없는 세션";
        const summary = if (self.last_user.len > 0) self.last_user else self.last_assistant;
        var parsed = try duplicateParsed(self.allocator, .codex, self.session_id, title, summary, self.cwd, false, self.model, self.count, true);
        parsed.last_activity_ns = self.last_activity_ns;
        return parsed;
    }
};

/// RFC 3339 UTC 시각(`YYYY-MM-DDTHH:MM:SS[.fff]Z`)을 Unix epoch 나노초로 바꾼다. 형태가 조금이라도
/// 다르면 **추측하지 않고** null을 돌려 호출자가 mtime으로 폴백하게 한다 — 틀린 시각으로 정렬하느니
/// 파일 시각이 낫다.
///
/// 실측(2026-08-08): 두 provider의 timestamp 200,025건이 모두 밀리초 3자리 `Z` 한 형태였다. 그래도
/// 소수부는 없거나 최대 9자리까지 받는다. 형태가 하나뿐이라고 파서를 그 하나에 못 박으면 provider가
/// 자릿수를 바꾸는 날 목록 순서가 조용히 mtime으로 돌아간다.
pub fn parseRfc3339Utc(text: []const u8) ?i96 {
    // `YYYY-MM-DDTHH:MM:SSZ`가 최소 형태다.
    if (text.len < 20 or text[text.len - 1] != 'Z') return null;
    if (text[4] != '-' or text[7] != '-' or text[13] != ':' or text[16] != ':') return null;
    if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return null;

    const year = twoWayInt(text[0..4]) orelse return null;
    const month = twoWayInt(text[5..7]) orelse return null;
    const day = twoWayInt(text[8..10]) orelse return null;
    const hour = twoWayInt(text[11..13]) orelse return null;
    const minute = twoWayInt(text[14..16]) orelse return null;
    // 윤초(60)를 허용한다. 거부하면 그 한 줄 때문에 파일 전체가 mtime으로 떨어진다.
    const second = twoWayInt(text[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var nanos: i96 = 0;
    const fraction = text[19 .. text.len - 1];
    if (fraction.len > 0) {
        if (fraction[0] != '.' or fraction.len > 10) return null;
        var scale: i96 = std.time.ns_per_s;
        for (fraction[1..]) |digit| {
            if (digit < '0' or digit > '9') return null;
            scale = @divTrunc(scale, 10);
            nanos += @as(i96, digit - '0') * scale;
        }
    }

    const days = daysFromCivil(year, month, day);
    const secs: i96 = days * std.time.s_per_day + @as(i96, hour) * 3600 + @as(i96, minute) * 60 + second;
    return secs * std.time.ns_per_s + nanos;
}

fn twoWayInt(text: []const u8) ?i32 {
    var value: i32 = 0;
    for (text) |digit| {
        if (digit < '0' or digit > '9') return null;
        value = value * 10 + (digit - '0');
    }
    return value;
}

/// 그레고리력 날짜를 1970-01-01 기준 일수로. Howard Hinnant의 `days_from_civil`이며 윤년·세기 규칙을
/// 분기 없이 처리한다.
fn daysFromCivil(year: i32, month: i32, day: i32) i96 {
    const y: i96 = @as(i96, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (@as(i96, month) + (if (month > 2) @as(i96, -3) else 9)) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// 버퍼 하나를 통째로 받는 진입점. `Parser`를 줄 단위로 돌린 것과 **결과가 같다** — fixture·테스트와
/// 부분 입력 비교가 이 등가성에 의존한다.
pub fn parse(allocator: std.mem.Allocator, provider: Provider, bytes: []const u8) !?Parsed {
    var parser = Parser.init(allocator, provider);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| parser.consumeLine(line);
    return parser.finish();
}

fn duplicateParsed(allocator: std.mem.Allocator, provider: Provider, session_id: []const u8, title: []const u8, summary: []const u8, cwd: []const u8, cwd_canonical: bool, model: []const u8, message_count: u32, verified_user: bool) !Parsed {
    // 필드 초기화식 안에 `try`를 늘어놓으면 앞서 성공한 dupe를 되돌릴 자리가 없다 — 뒤쪽 할당이
    // 실패할 때마다 문자열이 통째로 샜다. 한 단계씩 잡고 각자 errdefer를 건다.
    const session_copy = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_copy);
    const title_copy = try displayCopy(allocator, title, max_title_bytes);
    errdefer allocator.free(title_copy);
    const summary_copy = try displayCopy(allocator, summary, max_summary_bytes);
    errdefer allocator.free(summary_copy);
    const cwd_copy = try displayCopy(allocator, cwd, max_cwd_bytes);
    errdefer allocator.free(cwd_copy);
    const model_copy = try displayCopy(allocator, model, max_title_bytes);
    return .{
        .provider = provider,
        .session_id = session_copy,
        .title = title_copy,
        .summary = summary_copy,
        .cwd = cwd_copy,
        .cwd_canonical = cwd_canonical,
        .model = model_copy,
        .message_count = message_count,
        .verified_user = verified_user,
    };
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

// 정렬 키가 여기서 나온다. 형태를 잘못 읽으면 목록 순서가 조용히 틀리고, 거부해야 할 것을 받아들이면
// 엉뚱한 시각으로 정렬된다 — 둘 다 눈에 잘 띄지 않으므로 경계를 고정한다.
test "parseRfc3339Utc: epoch 변환과 거부 경계" {
    // 기준점들. epoch, 윤년(2000은 400의 배수라 윤년), 세기 비윤년(1900), 실측 형태.
    try std.testing.expectEqual(@as(?i96, 0), parseRfc3339Utc("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i96, 1_000_000_000 * std.time.ns_per_s), parseRfc3339Utc("2001-09-09T01:46:40Z"));
    try std.testing.expectEqual(@as(?i96, 951_782_400 * std.time.ns_per_s), parseRfc3339Utc("2000-02-29T00:00:00Z"));
    // 1900-03-01은 1900이 윤년이 아니어야 나오는 값이다(400 규칙).
    try std.testing.expectEqual(@as(?i96, -2_203_891_200 * std.time.ns_per_s), parseRfc3339Utc("1900-03-01T00:00:00Z"));

    // 실측 형태: 밀리초 3자리.
    try std.testing.expectEqual(
        @as(?i96, 1_754_652_783 * std.time.ns_per_s + 657 * std.time.ns_per_ms),
        parseRfc3339Utc("2025-08-08T11:33:03.657Z"),
    );
    // 소수부 자릿수는 provider가 바꿀 수 있다. 없는 것부터 나노초 9자리까지 받는다.
    try std.testing.expectEqual(@as(?i96, 1 * std.time.ns_per_s + 5 * std.time.ns_per_ms), parseRfc3339Utc("1970-01-01T00:00:01.005Z"));
    try std.testing.expectEqual(@as(?i96, 1 * std.time.ns_per_s + 123_456_789), parseRfc3339Utc("1970-01-01T00:00:01.123456789Z"));
    // 윤초를 거부하면 그 한 줄 때문에 파일 전체가 mtime으로 떨어진다.
    try std.testing.expect(parseRfc3339Utc("2016-12-31T23:59:60Z") != null);

    // 거부: 추측하지 않는다. 잘못 읽은 시각으로 정렬하느니 mtime이 낫다.
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T11:33:03")); // Z 없음
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T11:33:03+09:00")); // 오프셋
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08 11:33Z")); // 짧음
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-13-08T11:33:03Z")); // 13월
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T24:33:03Z")); // 24시
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("20xx-08-08T11:33:03Z")); // 숫자 아님
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T11:33:03.1234567890Z")); // 소수 10자리
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc(""));
}

// 정렬 키는 "마지막으로 본 줄"이 아니라 **가장 늦은 시각**이다. 요약·메타 줄이 뒤에 붙는 형식에서
// 마지막 줄의 시각이 더 이르면 세션이 목록 아래로 잘못 밀린다.
test "Parser: last_activity_ns는 줄 순서가 아니라 최댓값을 따른다" {
    const a = std.testing.allocator;
    var parsed = (try parse(a, .claude,
        \\{"sessionId":"s-1","cwd":"/repo","type":"user","timestamp":"2025-08-08T10:00:00Z","message":{"role":"user","text":"첫"}}
        \\{"type":"assistant","timestamp":"2025-08-08T12:00:00Z","message":{"role":"assistant","text":"응답"}}
        \\{"type":"summary","timestamp":"2025-08-08T11:00:00Z"}
        \\{"type":"assistant","message":{"role":"assistant","text":"시각 없는 줄"}}
    )).?;
    defer parsed.deinit(a);
    try std.testing.expectEqual(parseRfc3339Utc("2025-08-08T12:00:00Z").?, parsed.last_activity_ns);

    // 하나도 읽지 못하면 0으로 남아 호출자가 mtime으로 폴백한다.
    var none = (try parse(a, .claude,
        \\{"sessionId":"s-2","type":"user","message":{"role":"user","text":"시각 없음"}}
    )).?;
    defer none.deinit(a);
    try std.testing.expectEqual(@as(i96, 0), none.last_activity_ns);
}

// clone이 필드 하나를 빠뜨리면 캐시 히트와 부분 진행 발행에서만 값이 사라진다 — 첫 스캔은 멀쩡하고
// 두 번째부터 틀리므로 눈으로 잡기 어렵다. 필드 목록을 comptime으로 훑어 새 필드가 자동으로 검사에
// 들어오게 한다.
test "clone은 Parsed의 모든 필드를 보존한다" {
    const a = std.testing.allocator;
    var origin = try duplicateParsed(a, .codex, "s-1", "제목", "요약", "/repo", true, "gpt-x", 42, true);
    defer origin.deinit(a);
    origin.last_activity_ns = 1_234_567_890_123_456_789;

    var copy = try origin.clone(a);
    defer copy.deinit(a);

    inline for (@typeInfo(Parsed).@"struct".fields) |field| {
        const lhs = @field(origin, field.name);
        const rhs = @field(copy, field.name);
        const is_text = comptime blk: {
            const info = @typeInfo(field.type);
            break :blk info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
        };
        if (comptime is_text) {
            try std.testing.expectEqualStrings(lhs, rhs);
        } else {
            try std.testing.expectEqual(lhs, rhs);
        }
    }
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
