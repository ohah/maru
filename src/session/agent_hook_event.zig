//! provider 훅이 남긴 **이벤트 로그 한 줄**을 읽는 순수 파서와 tail 소비 상태(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md)이고, 이 파일은 그 §4(전달 채널)의
//! 코어다. 실제 파일 읽기는 platform이 하고, 여기서는 **바이트 → 이벤트**만 한다.
//!
//! **왜 JSON 라이브러리를 쓰지 않는가**: ⑴ 우리가 쓰는 필드는 십여 개뿐인데 payload에는 셸 명령 출력까지
//! 실려 전체를 트리로 만들 이유가 없고, ⑵ `std.json`의 typed 파싱은 f128 소프트플로트를 제품 링크로 끌어와
//! ReleaseSafe 빌드를 깨뜨린 전례가 있다(같은 이유로 알림 디코더도 손으로 짰다). 그래서 **구조를 아는 최소
//! 스캐너**를 둔다 — 문자열/이스케이프/중첩 깊이만 인지하고 나머지는 건너뛴다.
//!
//! **왜 깊이를 세는가**: 단순 문자열 검색은 값 안에 든 `"file_path"` 같은 글자에 걸린다. 에이전트가 그 단어를
//! 프롬프트에 쓰는 일은 흔하다. 그래서 최상위(depth 1)와 `tool_input` 안(depth 2)의 **키 위치**만 인정한다.

const std = @import("std");

/// 한 줄의 최대 길이. 넘으면 그 줄은 **버린다**(잘라서 반쪽 JSON을 만들지 않는다 — 파서가 어차피 거절하고,
/// 잘린 조각이 다음 줄과 붙는 사고만 는다). 훅 쪽도 같은 값으로 스스로 자른다.
///
/// **32 KiB인 근거(2026-08-20 실측)**: 우리 세트에서 가장 큰 이벤트가 `PreToolUse(Agent)` 4,249 B였고
/// 그 다음이 `PreToolUse(Bash)` 3,593 B였다. 거대한 `tool_response.stdout`·`originalFile`을 싣던
/// `PostToolUse`는 세트에서 뺐다(계약 §3.1). 8 KiB로 잡으면 긴 서브에이전트 프롬프트가 걸리고, 더 키우면
/// 훅이 한 번에 밀어 넣는 양만 는다.
pub const max_line_bytes: usize = 32 * 1024;

/// 한 tick에 처리할 이벤트 상한. 도구 폭주 구간에서 tick 하나가 수백 줄을 파싱하며 렌더를 붙잡지 않게 한다.
/// 남은 줄은 다음 tick이 이어서 읽는다(오프셋이 전진하므로 다시 읽지 않는다).
pub const max_events_per_tick: usize = 64;

/// 로그 한 줄의 provider 표식과 payload를 가르는 구분자. **payload에는 절대 나오지 않는다** — JSON은 제어문자를
/// 이스케이프하므로 raw 탭이 들어올 수 없다(실측: payload는 개행 없는 한 줄 JSON이다).
pub const field_separator: u8 = '\t';

/// 훅이 payload 길이 상한을 넘겼을 때 대신 적는 표식. **이벤트를 조용히 없애지 않는다** — 무엇이 잘렸는지
/// 세는 것과 아무 일도 없던 것은 다르다.
pub const oversized_marker = "__oversized__";

pub const Kind = enum {
    session_start,
    user_prompt_submit,
    stop,
    permission_request,
    pre_tool_use,
    notification,
    /// 상한을 넘겨 훅이 버린 이벤트. 종류를 알 수 없다.
    oversized,
    /// 우리가 걸지 않은 이벤트거나 모르는 이름. 소비자는 무시한다.
    unknown,
};

/// 한 이벤트. **모든 슬라이스는 입력 줄을 빌린다**(할당 없음) — 줄 버퍼가 살아 있는 동안만 유효하다.
/// 문자열 값은 **JSON 이스케이프가 남아 있는 원문**이다. 화면에 올릴 때만 `decodeInto`로 푼다.
pub const Event = struct {
    /// 훅이 줄 앞에 적은 provider 이름. payload에는 이 정보가 없어서 **우리가 붙인다**(계약 §4.1).
    provider: []const u8 = "",
    kind: Kind = .unknown,
    session_id: []const u8 = "",
    transcript_path: []const u8 = "",
    /// 턴 식별자. Claude는 `prompt_id`, Codex는 `turn_id`로 온다 — 같은 자리에 담는다.
    turn_key: []const u8 = "",
    tool_name: []const u8 = "",
    /// `tool_input.description` — 사람이 읽는 도구 설명. 진행 중 배지가 쓴다(명령 원문은 길고 민감해 쓰지 않는다).
    tool_description: []const u8 = "",
    /// `tool_input.file_path` — 편집 도구가 만지는 경로. AI 소행 확정이 쓴다.
    file_path: []const u8 = "",
    /// `UserPromptSubmit.prompt` 또는 `Stop.last_assistant_message`. 사이드바 대화 줄이 쓴다.
    text: []const u8 = "",
    /// `SessionStart.source`(startup/resume/…).
    source: []const u8 = "",
    /// 참이면 이 `Stop`은 재진입이므로 **턴 종료로 세지 않는다**(계약 §2).
    stop_hook_active: bool = false,
    /// `background_tasks`가 비어 있지 않다. 참이면 턴이 끝나도 **완료로 단정하지 않는다**(계약 §2).
    has_background_tasks: bool = false,
};

fn kindFromName(name: []const u8) Kind {
    const table = .{
        .{ "SessionStart", Kind.session_start },
        .{ "UserPromptSubmit", Kind.user_prompt_submit },
        .{ "Stop", Kind.stop },
        .{ "PermissionRequest", Kind.permission_request },
        .{ "PreToolUse", Kind.pre_tool_use },
        .{ "Notification", Kind.notification },
        .{ oversized_marker, Kind.oversized },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return .unknown;
}

/// 로그 한 줄을 이벤트로 읽는다. **손상된 줄은 조용히 `null`** 이다 — 동시 append로 섞이거나 상한에 잘린 줄이
/// 정상적으로 생길 수 있고(계약 §4), 그때 파서가 죽으면 그 뒤 모든 이벤트를 잃는다.
pub fn parseLine(line: []const u8) ?Event {
    const sep = std.mem.indexOfScalar(u8, line, field_separator) orelse return null;
    const provider = line[0..sep];
    if (provider.len == 0) return null;
    const json = std.mem.trim(u8, line[sep + 1 ..], " \r\n");
    if (json.len < 2 or json[0] != '{') return null;

    var ev: Event = .{ .provider = provider };
    var scan: Scanner = .{ .src = json };
    if (!scan.expectObjectStart()) return null;

    var saw_event_name = false;
    while (scan.nextKey(1)) |key| {
        if (std.mem.eql(u8, key, "hook_event_name")) {
            const v = scan.stringValue() orelse return null;
            ev.kind = kindFromName(v);
            saw_event_name = true;
        } else if (std.mem.eql(u8, key, "session_id")) {
            ev.session_id = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "transcript_path")) {
            ev.transcript_path = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "prompt_id") or std.mem.eql(u8, key, "turn_id")) {
            ev.turn_key = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "tool_name")) {
            ev.tool_name = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "source")) {
            ev.source = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "prompt") or std.mem.eql(u8, key, "last_assistant_message")) {
            ev.text = scan.stringValue() orelse return null;
        } else if (std.mem.eql(u8, key, "stop_hook_active")) {
            ev.stop_hook_active = scan.boolValue() orelse return null;
        } else if (std.mem.eql(u8, key, "background_tasks")) {
            ev.has_background_tasks = scan.nonEmptyArrayValue() orelse return null;
        } else if (std.mem.eql(u8, key, "tool_input")) {
            // 중첩 객체 안에서도 **키 위치**만 본다. 값 안에 같은 단어가 있어도 걸리지 않는다.
            if (!scan.expectObjectStart()) {
                if (!scan.skipValueAfterPeek()) return null;
                continue;
            }
            while (scan.nextKey(2)) |inner| {
                if (std.mem.eql(u8, inner, "file_path")) {
                    ev.file_path = scan.stringValue() orelse return null;
                } else if (std.mem.eql(u8, inner, "description")) {
                    ev.tool_description = scan.stringValue() orelse return null;
                } else if (!scan.skipValue()) return null;
            }
            if (scan.failed) return null;
        } else if (!scan.skipValue()) return null;
    }
    if (scan.failed) return null;
    if (!saw_event_name) return null;
    return ev;
}

/// JSON 문자열 이스케이프를 풀어 `out`에 담는다(표시 직전에만 쓴다). 담을 수 있는 만큼만 담고 자른다 —
/// 사이드바 한 줄에 들어갈 분량이면 충분하고, 여기서 할당하지 않기 위해서다.
/// `\uXXXX`는 **대체 문자 하나로** 접는다: 이 자리에 필요한 것은 사람이 읽을 한 줄이지 정확한 코드포인트 복원이
/// 아니고, surrogate pair까지 다루면 파서가 이 모듈의 목적보다 커진다.
pub fn decodeInto(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len and n < out.len) {
        const c = raw[i];
        if (c != '\\') {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) break;
        const esc = raw[i + 1];
        i += 2;
        const mapped: u8 = switch (esc) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'u' => blk: {
                i = @min(i + 4, raw.len); // 코드포인트는 건너뛰고 자리만 지킨다
                break :blk '?';
            },
            else => esc,
        };
        out[n] = mapped;
        n += 1;
    }
    return out[0..n];
}

/// 로그 파일 하나의 tail 소비 상태. **오프셋만 든다** — 버퍼는 호출자가 소유한다(플랫폼이 읽어 넘긴다).
pub const Cursor = struct {
    /// 다음에 읽기 시작할 바이트 위치.
    offset: u64 = 0,

    pub const Batch = struct {
        /// 이번에 채운 이벤트 수.
        count: usize,
        /// 오프셋을 이만큼 전진시킨다(마지막 **완결된 줄**까지만).
        consumed: usize,
        /// 상한에 걸려 버린 줄 수. 0이 아니면 관측에 센다(내용은 남기지 않는다 — 계약 §7).
        dropped: usize,
        /// 상한(`max_events_per_tick`)에 걸려 남은 줄이 있다. 다음 tick이 이어 읽는다.
        more: bool,
    };

    /// `chunk`(파일의 `offset` 이후 바이트)에서 완결된 줄만 뽑아 `out`에 채운다.
    ///
    /// **마지막 줄에 개행이 없으면 그 줄은 남긴다.** 훅이 쓰는 중일 수 있고, 반쪽 줄을 파싱하면 정상 이벤트를
    /// 손상으로 오인해 버린다. 그 줄은 다음 tick에 완결된 채로 다시 온다(오프셋을 전진시키지 않았으므로).
    pub fn take(self: *Cursor, chunk: []const u8, out: []Event) Batch {
        var count: usize = 0;
        var dropped: usize = 0;
        var consumed: usize = 0;
        const limit = @min(out.len, max_events_per_tick);
        var rest = chunk;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
            const line = rest[0..nl];
            const advance = nl + 1;
            if (count == limit) break;
            rest = rest[advance..];
            consumed += advance;
            if (line.len == 0) continue; // 빈 줄은 정상이다(훅이 상한 처리로 남길 수 있다)
            if (line.len > max_line_bytes) {
                dropped += 1;
                continue;
            }
            if (parseLine(line)) |ev| {
                out[count] = ev;
                count += 1;
            } else {
                dropped += 1;
            }
        }
        self.offset += consumed;
        return .{
            .count = count,
            .consumed = consumed,
            .dropped = dropped,
            .more = std.mem.indexOfScalar(u8, rest, '\n') != null,
        };
    }

    /// 파일이 회전(rename 후 새로 생성)되면 오프셋을 되돌린다. **크기가 줄었다는 것이 유일한 신호**다 —
    /// inode를 보는 것은 platform의 몫이고, 이 순수 층은 크기만으로 판정한다.
    pub fn resetIfTruncated(self: *Cursor, file_size: u64) bool {
        if (file_size >= self.offset) return false;
        self.offset = 0;
        return true;
    }
};

// ─── 최소 JSON 스캐너 ────────────────────────────────────────────────────────
// 목적은 «키를 정확한 깊이에서 찾고 나머지는 건너뛰기»다. 숫자·null의 값 형태는 검증하지 않는다 —
// 우리가 읽는 것은 문자열·불리언·배열의 빈 여부뿐이고, 나머지는 건너뛰기만 하면 된다.

const Scanner = struct {
    src: []const u8,
    i: usize = 0,
    failed: bool = false,

    fn skipWs(self: *Scanner) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn peek(self: *Scanner) ?u8 {
        self.skipWs();
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    fn expectObjectStart(self: *Scanner) bool {
        const c = self.peek() orelse return false;
        if (c != '{') return false;
        self.i += 1;
        return true;
    }

    /// `depth` 위치의 다음 키를 돌려준다(객체가 닫히면 `null`). 값은 호출자가 읽거나 건너뛴다.
    fn nextKey(self: *Scanner, depth: usize) ?[]const u8 {
        _ = depth; // 깊이는 호출 구조가 보장한다(중첩 진입은 호출자가 명시적으로 한다)
        if (self.failed) return null;
        var c = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (c == ',') {
            self.i += 1;
            c = self.peek() orelse {
                self.failed = true;
                return null;
            };
        }
        if (c == '}') {
            self.i += 1;
            return null;
        }
        const key = self.rawString() orelse {
            self.failed = true;
            return null;
        };
        const colon = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (colon != ':') {
            self.failed = true;
            return null;
        }
        self.i += 1;
        return key;
    }

    /// 따옴표 안의 **원문**(이스케이프 미해제)을 돌려주고 커서를 닫는 따옴표 뒤로 옮긴다.
    fn rawString(self: *Scanner) ?[]const u8 {
        const c = self.peek() orelse return null;
        if (c != '"') return null;
        self.i += 1;
        const start = self.i;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '\\') {
                // 이스케이프는 두 바이트를 통째로 건너뛴다 — `\"`가 문자열을 닫는 것으로 오인되지 않게.
                self.i += 2;
                continue;
            }
            if (ch == '"') {
                const out = self.src[start..self.i];
                self.i += 1;
                return out;
            }
            self.i += 1;
        }
        return null;
    }

    fn stringValue(self: *Scanner) ?[]const u8 {
        const v = self.rawString();
        if (v == null) self.failed = true;
        return v;
    }

    fn boolValue(self: *Scanner) ?bool {
        const c = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (c == 't' and self.remaining() >= 4) {
            self.i += 4;
            return true;
        }
        if (c == 'f' and self.remaining() >= 5) {
            self.i += 5;
            return false;
        }
        // 불리언이 아니면 값을 건너뛰고 «없음»으로 본다(형이 바뀌어도 줄 전체를 잃지 않게).
        if (!self.skipValue()) {
            self.failed = true;
            return null;
        }
        return false;
    }

    /// 배열 값을 건너뛰면서 **비어 있지 않은지**만 답한다.
    fn nonEmptyArrayValue(self: *Scanner) ?bool {
        const c = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (c != '[') {
            if (!self.skipValue()) {
                self.failed = true;
                return null;
            }
            return false;
        }
        self.i += 1;
        const inner = self.peek() orelse {
            self.failed = true;
            return null;
        };
        if (inner == ']') {
            self.i += 1;
            return false;
        }
        // 비어 있지 않다 — 나머지는 건너뛴다.
        var depth: usize = 1;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '"') {
                _ = self.rawString() orelse {
                    self.failed = true;
                    return null;
                };
                continue;
            }
            self.i += 1;
            if (ch == '[' or ch == '{') depth += 1;
            if (ch == ']' or ch == '}') {
                depth -= 1;
                if (depth == 0) return true;
            }
        }
        self.failed = true;
        return null;
    }

    fn remaining(self: *Scanner) usize {
        return self.src.len - self.i;
    }

    /// 다음 값 하나를 통째로 건너뛴다(문자열·객체·배열·그 밖).
    fn skipValue(self: *Scanner) bool {
        const c = self.peek() orelse return false;
        return self.skipValueWith(c);
    }

    /// `peek`으로 이미 `{`를 본 뒤 그것이 객체가 아니었을 때 쓰는 경로.
    fn skipValueAfterPeek(self: *Scanner) bool {
        return self.skipValue();
    }

    fn skipValueWith(self: *Scanner, c: u8) bool {
        if (c == '"') {
            return self.rawString() != null;
        }
        if (c == '{' or c == '[') {
            var depth: usize = 0;
            while (self.i < self.src.len) {
                const ch = self.src[self.i];
                if (ch == '"') {
                    _ = self.rawString() orelse return false;
                    continue;
                }
                self.i += 1;
                if (ch == '{' or ch == '[') depth += 1;
                if (ch == '}' or ch == ']') {
                    depth -= 1;
                    if (depth == 0) return true;
                }
            }
            return false;
        }
        // 숫자·true·false·null: 구분자 전까지 먹는다.
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ',', '}', ']' => return true,
                else => {},
            }
        }
        return false;
    }
};

const testing = std.testing;

test "실측 payload 모양을 그대로 읽는다 — SessionStart" {
    // 2026-08-20 실측(Claude, 격리 설정 + 헤드리스 1회)에서 회수한 필드 구성이다.
    const line = "claude\t{\"session_id\":\"9efa0c23\",\"transcript_path\":\"/x/y.jsonl\",\"cwd\":\"/w\"," ++
        "\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("claude", ev.provider);
    try testing.expectEqual(Kind.session_start, ev.kind);
    try testing.expectEqualStrings("9efa0c23", ev.session_id);
    try testing.expectEqualStrings("/x/y.jsonl", ev.transcript_path);
    try testing.expectEqualStrings("startup", ev.source);
}

test "Stop의 재진입 가드와 background_tasks를 읽는다" {
    // `stop_hook_active`가 참이면 턴 종료가 아니고, `background_tasks`가 비어 있지 않으면 완료가 아니다.
    const busy = "codex\t{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\"," ++
        "\"background_tasks\":[{\"id\":\"bc3k\",\"status\":\"running\"}]," ++
        "\"stop_hook_active\":false,\"last_assistant_message\":\"끝났습니다\"}";
    const ev = parseLine(busy).?;
    try testing.expectEqual(Kind.stop, ev.kind);
    try testing.expectEqualStrings("p1", ev.turn_key);
    try testing.expect(ev.has_background_tasks);
    try testing.expect(!ev.stop_hook_active);
    try testing.expectEqualStrings("끝났습니다", ev.text);

    const idle = "codex\t{\"hook_event_name\":\"Stop\",\"background_tasks\":[],\"stop_hook_active\":true}";
    const ev2 = parseLine(idle).?;
    try testing.expect(!ev2.has_background_tasks);
    try testing.expect(ev2.stop_hook_active);
}

test "tool_input 안의 키만 인정한다 — 값에 든 같은 단어에 걸리지 않는다" {
    // 에이전트가 프롬프트에 `file_path`를 언급하는 일은 흔하다. 최상위 문자열 값에 든 그 단어를 경로로 읽으면
    // 고치지도 않은 파일이 «AI 편집»으로 표시된다.
    const line = "claude\t{\"hook_event_name\":\"UserPromptSubmit\"," ++
        "\"prompt\":\"tool_input 의 file_path 를 설명해줘\"}";
    const ev = parseLine(line).?;
    try testing.expectEqual(Kind.user_prompt_submit, ev.kind);
    try testing.expectEqualStrings("", ev.file_path);
    try testing.expectEqualStrings("tool_input 의 file_path 를 설명해줘", ev.text);

    const edit = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\"," ++
        "\"tool_input\":{\"file_path\":\"/repo/src/a.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}}";
    const ev2 = parseLine(edit).?;
    try testing.expectEqualStrings("/repo/src/a.zig", ev2.file_path);
    try testing.expectEqualStrings("Edit", ev2.tool_name);
}

test "PreToolUse(Bash)는 description을 싣고 명령 원문은 배지가 쓰지 않는다" {
    const line = "claude\t{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"," ++
        "\"tool_input\":{\"command\":\"npm run build\",\"description\":\"빌드 실행\",\"timeout\":120000}}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("Bash", ev.tool_name);
    try testing.expectEqualStrings("빌드 실행", ev.tool_description);
    try testing.expectEqualStrings("", ev.file_path); // Bash에는 경로가 없다
}

test "이스케이프된 따옴표가 문자열을 닫지 않는다" {
    // `\"`를 종료로 오인하면 그 뒤 키가 값으로 밀려 이벤트 전체가 어긋난다.
    const line = "claude\t{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"그는 \\\"네\\\"라고 했다\"," ++
        "\"prompt_id\":\"p9\"}";
    const ev = parseLine(line).?;
    try testing.expectEqualStrings("p9", ev.turn_key);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("그는 \"네\"라고 했다", decodeInto(&buf, ev.text));
}

test "손상된 줄은 조용히 버린다 — 동시 append로 섞일 수 있다" {
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("claude") == null); // 구분자 없음
    try testing.expect(parseLine("\t{}") == null); // provider 없음
    try testing.expect(parseLine("claude\tnot-json") == null);
    try testing.expect(parseLine("claude\t{\"hook_event_name\":\"Stop\"") == null); // 잘림
    try testing.expect(parseLine("claude\t{\"session_id\":\"x\"}") == null); // 이벤트 이름 없음
}

test "모르는 이벤트는 버리지 않고 unknown으로 든다" {
    // 버리면 provider가 이벤트를 늘렸을 때 «아무 일도 없음»과 구분되지 않는다.
    const ev = parseLine("claude\t{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\"}").?;
    try testing.expectEqual(Kind.unknown, ev.kind);
    try testing.expectEqualStrings("Edit", ev.tool_name);
}

test "상한을 넘긴 이벤트는 표식으로 남는다 — 조용히 사라지지 않는다" {
    const ev = parseLine("claude\t{\"hook_event_name\":\"" ++ oversized_marker ++ "\"}").?;
    try testing.expectEqual(Kind.oversized, ev.kind);
}

test "커서는 완결된 줄만 소비하고 반쪽 줄을 남긴다" {
    var cur: Cursor = .{};
    var out: [8]Event = undefined;
    const chunk = "claude\t{\"hook_event_name\":\"SessionStart\"}\n" ++
        "claude\t{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}\n" ++
        "claude\t{\"hook_event_name\":\"Sto"; // 훅이 쓰는 중
    const batch = cur.take(chunk, &out);
    try testing.expectEqual(@as(usize, 2), batch.count);
    try testing.expectEqual(@as(usize, 0), batch.dropped);
    try testing.expectEqual(Kind.session_start, out[0].kind);
    try testing.expectEqual(Kind.user_prompt_submit, out[1].kind);
    // 반쪽 줄은 오프셋에 넣지 않는다 — 다음 tick에 완결된 채로 다시 온다.
    const half_len = "claude\t{\"hook_event_name\":\"Sto".len;
    try testing.expectEqual(chunk.len - half_len, batch.consumed);
    try testing.expectEqual(@as(u64, chunk.len - half_len), cur.offset);
}

test "tick당 상한을 지키고 남은 줄을 다음 tick에 넘긴다" {
    var cur: Cursor = .{};
    var out: [2]Event = undefined;
    const one = "claude\t{\"hook_event_name\":\"Stop\"}\n";
    const chunk = one ++ one ++ one ++ one;
    const first = cur.take(chunk, &out);
    try testing.expectEqual(@as(usize, 2), first.count);
    try testing.expect(first.more);
    try testing.expectEqual(@as(u64, one.len * 2), cur.offset);

    const second = cur.take(chunk[first.consumed..], &out);
    try testing.expectEqual(@as(usize, 2), second.count);
    try testing.expect(!second.more);
    try testing.expectEqual(@as(u64, chunk.len), cur.offset);
}

test "긴 줄은 버리고 그 사실을 센다 — 그 줄이 다음 줄을 먹지 않는다" {
    var cur: Cursor = .{};
    var out: [4]Event = undefined;
    var big: [max_line_bytes + 64]u8 = undefined;
    @memset(&big, 'x');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, &big);
    try buf.append(testing.allocator, '\n');
    try buf.appendSlice(testing.allocator, "claude\t{\"hook_event_name\":\"Stop\"}\n");

    const batch = cur.take(buf.items, &out);
    try testing.expectEqual(@as(usize, 1), batch.count);
    try testing.expectEqual(@as(usize, 1), batch.dropped);
    try testing.expectEqual(Kind.stop, out[0].kind);
}

test "빈 줄은 손상이 아니다" {
    var cur: Cursor = .{};
    var out: [4]Event = undefined;
    const batch = cur.take("\n\nclaude\t{\"hook_event_name\":\"Stop\"}\n", &out);
    try testing.expectEqual(@as(usize, 1), batch.count);
    try testing.expectEqual(@as(usize, 0), batch.dropped);
}

test "파일이 회전하면 오프셋을 되돌린다" {
    var cur: Cursor = .{ .offset = 4096 };
    try testing.expect(!cur.resetIfTruncated(4096)); // 같은 크기 = 그대로
    try testing.expect(!cur.resetIfTruncated(8192)); // 자란 것 = 그대로
    try testing.expect(cur.resetIfTruncated(10)); // 줄었다 = 회전
    try testing.expectEqual(@as(u64, 0), cur.offset);
}

test "decodeInto는 담을 수 있는 만큼만 담는다" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", decodeInto(&buf, "abcdefgh"));
    var nl: [8]u8 = undefined;
    try testing.expectEqualStrings("a\nb", decodeInto(&nl, "a\\nb"));
    var uni: [8]u8 = undefined;
    try testing.expectEqualStrings("a?b", decodeInto(&uni, "a\\u0041b")); // 코드포인트는 자리만 지킨다
}
