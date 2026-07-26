//! 에이전트 **세션 기록 파일**(transcript)에서 마지막 대화를 읽는다 — 사이드바 에이전트 행의 프롬프트·응답 줄
//! (docs/sidebar-agent-list.md §7)의 단일 출처.
//!
//! **왜 화면이 아니라 파일인가**: 상태 판정(`agent_observer`)은 짧은 마커라 화면에서 뽑을 수 있지만, 대화 **본문**은
//! `/clear`를 하거나 응답이 길어 스크롤 밖으로 밀리면 **화면에 존재하지 않는다**. 화면은 대화의 렌더 결과이지
//! 대화가 아니다.
//!
//! **왜 훅이 아닌가**: 세션 파일과 Term을 잇는 데 provider 훅(사용자 config 수정)이 필요하지 않다는 것을 실측으로
//! 확인했다(§7.2). 훅은 사용자 설정 파일을 고쳐 쓰고 설치·제거·자가정리를 유지해야 하며 사용자가 그 설정을 손대면
//! 조용히 깨진다.
//!
//! **계약**(§7.1) — 이 모듈의 모든 함수가 지킨다:
//! 1. **선택적 보강이다.** 어떤 실패도 error가 아니라 **빈 결과**로 돌아온다. 행은 아이콘·상태로 정상 동작하고
//!    대화 줄만 빈다. 이 계약이 없으면 provider가 포맷을 바꿀 때 목록 전체가 죽는다.
//! 2. **프로세스에서 파일을 추론하지 않는다.** 매핑을 고정하지 않고 "그 Term이 출력한 시점에 갱신된 파일"을
//!    매번 따라간다(호출부 책임 — §7.2 반증 2: `/clear`로 같은 프로세스가 파일을 갈아탄다).
//! 3. **서브에이전트를 배제한다.** claude는 서브에이전트 기록이 `<세션 id>/` **하위 디렉터리**에 쌓이므로 직속
//!    파일만 훑으면 배제된다(§7.3). 실측: 직속 54개 ↔ 하위 포함 1805개.
//! 4. **tail만 읽는다.** 47MB 파일도 끝 `max_tail_bytes`만 본다(§7.4).
//!
//! OS 중립이다 — `std.fs`만 쓰고 macOS 타입에 닿지 않는다.

const std = @import("std");

/// 한 번에 읽는 파일 꼬리 크기. 실측(§7.4): 이 크기 안에 last-prompt 7건·assistant 텍스트 11건이 들어 있었다.
/// 더 키우면 도구 결과가 거대한 세션에서 회수율이 오르지만 매 폴링 비용도 그만큼 오른다 — 계약 1이 있으므로
/// 못 찾으면 그 줄만 비고, 다음 대화 때 다시 잡힌다.
pub const max_tail_bytes: usize = 256 * 1024;

/// 표시용 상한. 사이드바 폭이 좁아 이보다 길면 어차피 잘리고, 무한정 복사할 이유가 없다.
pub const max_text_bytes: usize = 512;

/// 한 세션의 마지막 대화. 빈 슬라이스 = 그 줄 없음(계약 1).
pub const Conversation = struct {
    /// 마지막 **사용자** 프롬프트.
    prompt: []const u8 = "",
    /// 마지막 **에이전트** 응답 텍스트.
    reply: []const u8 = "",
    /// 이 기록이 주장하는 작업 디렉터리. 호출부가 Term의 cwd와 대조해 **오매핑을 거른다**(§7.3 — 디렉터리 이름
    /// 인코딩 규칙이 불완전해도 여기서 걸린다).
    cwd: []const u8 = "",

    pub fn isEmpty(self: Conversation) bool {
        return self.prompt.len == 0 and self.reply.len == 0;
    }
};

/// `Conversation`이 가리키는 실제 바이트를 담는 소유 버퍼. 슬라이스가 이 안을 가리키므로 **함께 살아야 한다**.
pub const Owned = struct {
    buf: [max_text_bytes * 3]u8 = undefined,
    used: usize = 0,
    conversation: Conversation = .{},

    /// `text`를 이 버퍼에 복사하고 그 슬라이스를 준다. 상한을 넘으면 앞부분만 남긴다(잘라도 UTF-8 경계는 지킨다).
    pub fn store(self: *Owned, text: []const u8) []const u8 {
        const room = self.buf.len - self.used;
        const n = @min(text.len, @min(room, max_text_bytes));
        if (n == 0) return "";
        @memcpy(self.buf[self.used..][0..n], text[0..n]);
        const out = self.buf[self.used..][0..trimToCharBoundary(self.buf[self.used..][0..n])];
        self.used += n;
        return out;
    }
};

/// 세션 파일 이름 상한. claude는 `<uuid>.jsonl`(41자)이라 넉넉하다.
pub const max_name_bytes: usize = 128;

/// Term마다 드는 **매핑 + 대화 캐시**. 힙을 잡지 않는다(고정 크기) — Term 생애와 함께 죽으므로 해제가 필요 없고,
/// 매 폴링마다 할당/해제하면 tick 비용이 는다.
///
/// **매핑을 고정하지 않는다**(계약 2). `mapped_output_ms`가 그 규율의 구현이다 — Term이 새로 출력할 때마다
/// (= 이 값이 `agent_last_output_ms`와 어긋날 때마다) 디렉터리를 다시 훑어 그 시점의 최신 파일을 채택한다.
/// `/clear`로 같은 프로세스가 파일을 갈아타도, resume으로 옛 파일에 이어 써도 자동으로 따라간다.
pub const Cache = struct {
    name: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    /// 마지막으로 **읽어서 파싱한** 파일 mtime. 그대로면 다시 읽지 않는다(계약 4).
    read_mtime_ns: i96 = 0,
    /// 마지막 폴링 시각(awake ms) — throttle.
    last_poll_ms: u64 = 0,
    /// 매핑을 채택할 때 기준이 된 Term 출력 시각. 위 설명 참조.
    mapped_output_ms: u64 = 0,
    owned: Owned = .{},

    pub fn fileName(self: *const Cache) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setFileName(self: *Cache, name: []const u8) void {
        const n = @min(name.len, self.name.len);
        @memcpy(self.name[0..n], name[0..n]);
        self.name_len = n;
    }

    /// 매핑과 대화를 모두 버린다. cwd가 바뀌었거나 기록이 그 Term의 것이 아님이 드러났을 때.
    pub fn reset(self: *Cache) void {
        self.name_len = 0;
        self.read_mtime_ns = 0;
        self.mapped_output_ms = 0;
        self.owned.used = 0;
        self.owned.conversation = .{};
    }

    pub fn prompt(self: *const Cache) []const u8 {
        return self.owned.conversation.prompt;
    }

    pub fn reply(self: *const Cache) []const u8 {
        return self.owned.conversation.reply;
    }
};

/// `text`를 `max` 바이트 이하로 자르되 UTF-8 시퀀스를 쪼개지 않는다. 알림처럼 표시 폭이 더 좁은 곳에서 쓴다.
pub fn clampUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    return text[0..trimToCharBoundary(text[0..max])];
}

/// UTF-8 시퀀스 한가운데서 자르지 않도록 길이를 뒤로 줄인다. 잘린 바이트를 그대로 두면 렌더가 U+FFFD를 뿌린다.
fn trimToCharBoundary(text: []const u8) usize {
    var n = text.len;
    while (n > 0) {
        const len = std.unicode.utf8ByteSequenceLength(text[n - 1]) catch {
            // continuation byte(10xxxxxx) — 시퀀스 중간이다. 시작 바이트를 찾아 뒤로 간다.
            n -= 1;
            continue;
        };
        if (len == 1) return n; // ASCII: 여기서 끝나도 안전
        // 시작 바이트다. 그 시퀀스가 통째로 들어왔으면 포함, 아니면 잘라낸다.
        return if (n - 1 + len <= text.len) n - 1 + len else n - 1;
    }
    return 0;
}

/// cwd → claude 프로젝트 디렉터리 이름. **실측으로 역추론한 규칙**: `/`와 `.`을 `-`로 치환하는 1:1 매핑이다
/// (기존 프로젝트 디렉터리 8개를 각 파일의 `cwd` 필드와 문자 단위로 대조 — 길이 불일치 0, 대문자 보존).
///
/// 규칙이 모든 문자를 덮는다고 **가정하지 않는다**: provider가 다른 문자도 치환한다면 여기서 만든 이름의
/// 디렉터리가 없어 보강이 조용히 비고(계약 1), 우연히 다른 디렉터리와 겹치더라도 `Conversation.cwd` 대조가
/// 걸러낸다. 그래서 이 함수는 추측을 늘리는 대신 확인된 둘만 치환한다.
///
/// buf가 모자라면 null(계약 1).
pub fn claudeDirName(cwd: []const u8, buf: []u8) ?[]const u8 {
    if (cwd.len == 0 or cwd.len > buf.len) return null;
    for (cwd, 0..) |c, i| buf[i] = if (c == '/' or c == '.') '-' else c;
    return buf[0..cwd.len];
}

/// 디렉터리의 **직속** `.jsonl` 중 mtime이 가장 최근인 것. 하위 디렉터리로 내려가지 않으므로 claude 서브에이전트
/// 기록이 자동으로 배제된다(계약 3).
///
/// 이름을 `name_buf`에 쓰고 반환한다. 열 수 없거나 후보가 없으면 null(계약 1).
pub fn latestSessionFile(io: std.Io, dir: std.Io.Dir, name_buf: []u8) ?struct { name: []const u8, mtime_ns: i96 } {
    var it = dir.iterate();
    var best_ns: i96 = 0;
    var best_len: usize = 0;
    while ((it.next(io) catch return null)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (entry.name.len > name_buf.len) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        const ns = st.mtime.nanoseconds;
        if (best_len != 0 and ns <= best_ns) continue;
        @memcpy(name_buf[0..entry.name.len], entry.name);
        best_len = entry.name.len;
        best_ns = ns;
    }
    if (best_len == 0) return null;
    return .{ .name = name_buf[0..best_len], .mtime_ns = best_ns };
}

/// 파일 **끝** `buf.len` 바이트. 첫 줄은 중간에서 잘렸을 수 있으므로 버린다(부분 JSON을 파싱하면 잡음이 된다).
/// 실패는 빈 슬라이스(계약 1).
pub fn readTail(io: std.Io, dir: std.Io.Dir, name: []const u8, buf: []u8) []const u8 {
    const file = dir.openFile(io, name, .{}) catch return "";
    defer file.close(io);
    const size = (file.stat(io) catch return "").size;
    const want: usize = @intCast(@min(size, buf.len));
    if (want == 0) return "";
    const start = size - want;
    const n = file.readPositionalAll(io, buf[0..want], start) catch return "";
    const tail = buf[0..n];
    if (start == 0) return tail; // 파일 전체 — 첫 줄이 온전하다
    const nl = std.mem.indexOfScalar(u8, tail, '\n') orelse return "";
    return tail[nl + 1 ..];
}

/// claude JSONL tail에서 마지막 대화를 뽑는다(순수 — IO 없음).
///
/// **왜 `last-prompt` 레코드인가**: `type == "user"` 레코드는 대부분 도구 결과이고, 사람이 치지 않은 자동 입력
/// (컨텍스트 요약 이어받기, 백그라운드 작업 알림)도 같은 모양으로 섞인다. provider가 따로 남기는 `last-prompt`는
/// **사람이 실제로 친 것만** 담는다(실측: 같은 파일에서 user 후보 77건 중 자동 입력이 섞였고, last-prompt 152건은
/// 전부 실입력). 이 레코드가 없는 버전이면 프롬프트 줄만 빈다(계약 1) — user 레코드를 추측으로 걸러 잘못된 텍스트를
/// 보여주느니 비우는 편이 낫다.
///
/// 뒤에서 앞으로 훑으며 필요한 것을 다 찾으면 멈춘다 — tail 전체를 파싱하지 않는다.
pub fn parseClaudeTail(allocator: std.mem.Allocator, tail: []const u8, out: *Owned) void {
    out.used = 0;
    out.conversation = .{};

    var scratch: [max_text_bytes]u8 = undefined;
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    var want_prompt = true;
    var want_reply = true;
    var want_cwd = true;
    while (it.next()) |line| {
        if (!want_prompt and !want_reply and !want_cwd) break;
        if (line.len < 2 or line[0] != '{') continue;

        // JSON 파싱 전에 값싼 문자열 검사로 후보만 거른다 — tail 안 대부분의 줄은 도구 결과라 파싱이 낭비다.
        const is_prompt = want_prompt and std.mem.indexOf(u8, line, "\"last-prompt\"") != null;
        const is_reply = want_reply and std.mem.indexOf(u8, line, "\"assistant\"") != null;
        if (!is_prompt and !is_reply and !(want_cwd and std.mem.indexOf(u8, line, "\"cwd\"") != null)) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        if (want_cwd) {
            if (obj.get("cwd")) |v| switch (v) {
                .string => |s| {
                    out.conversation.cwd = out.store(s);
                    want_cwd = false;
                },
                else => {},
            };
        }

        const rec_type: []const u8 = switch (obj.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        };

        if (want_prompt and std.mem.eql(u8, rec_type, "last-prompt")) {
            if (obj.get("lastPrompt")) |v| switch (v) {
                .string => |s| {
                    const flat = flatten(s, &scratch);
                    if (flat.len > 0) {
                        out.conversation.prompt = out.store(flat);
                        want_prompt = false;
                    }
                },
                else => {},
            };
            continue;
        }

        if (want_reply and std.mem.eql(u8, rec_type, "assistant")) {
            // 서브에이전트 대화가 같은 파일에 sidechain으로 실릴 수 있다 — 사용자 카드에 내부 대화를 띄우지 않는다.
            if (obj.get("isSidechain")) |v| switch (v) {
                .bool => |b| if (b) continue,
                else => {},
            };
            const msg = switch (obj.get("message") orelse std.json.Value{ .null = {} }) {
                .object => |m| m,
                else => continue,
            };
            const content = switch (msg.get("content") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => continue,
            };
            // 한 응답 안에 thinking·tool_use가 섞이므로 **마지막 text 블록**만 쓴다.
            var found: []const u8 = "";
            for (content.items) |block| {
                const bo = switch (block) {
                    .object => |b| b,
                    else => continue,
                };
                const bt = switch (bo.get("type") orelse std.json.Value{ .null = {} }) {
                    .string => |s| s,
                    else => continue,
                };
                if (!std.mem.eql(u8, bt, "text")) continue;
                switch (bo.get("text") orelse std.json.Value{ .null = {} }) {
                    .string => |s| found = s,
                    else => {},
                }
            }
            if (found.len > 0) {
                const flat = flatten(found, &scratch);
                if (flat.len > 0) {
                    out.conversation.reply = out.store(flat);
                    want_reply = false;
                }
            }
        }
    }
}

/// 여러 줄 텍스트를 사이드바 **한 줄**로 눕힌다: 개행·탭을 공백으로, 연속 공백을 하나로, 앞뒤 공백 제거.
/// 마크다운 기호는 그대로 둔다 — 없애면 코드 조각이나 목록이 뜻을 잃고, 잘라 보여주는 미리보기라 원문이 낫다.
fn flatten(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (text) |c| {
        if (n >= buf.len) break;
        const is_space = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (is_space) {
            if (n > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (n >= buf.len) break;
            buf[n] = ' ';
            n += 1;
            pending_space = false;
            if (n >= buf.len) break;
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..trimToCharBoundary(buf[0..n])];
}

const testing = std.testing;

test "claudeDirName: 실측 규칙(/ · . → -)을 그대로 따른다" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "-Users-yoonhb-Documents-workspace-maru",
        claudeDirName("/Users/yoonhb/Documents/workspace/maru", &buf).?,
    );
    // 점도 치환된다(실측 대조에서 확인된 둘 중 하나) — `.config` 같은 경로가 조용히 빗나가지 않게.
    try testing.expectEqualStrings("-home-me--config-app", claudeDirName("/home/me/.config/app", &buf).?);
    // 하이픈은 원래 이름에 있을 수 있고 그대로 둔다(역변환이 모호한 이유이기도 하다).
    try testing.expectEqualStrings("-a-react-native-mcp", claudeDirName("/a/react-native-mcp", &buf).?);
    // 계약 1: 빈 cwd·버퍼 부족은 error가 아니라 null이다.
    try testing.expect(claudeDirName("", &buf) == null);
    var tiny: [4]u8 = undefined;
    try testing.expect(claudeDirName("/very/long/path", &tiny) == null);
}

test "parseClaudeTail: last-prompt와 마지막 assistant text를 뽑고 cwd를 싣는다" {
    const tail =
        \\{"type":"user","cwd":"/w/maru","message":{"role":"user","content":[{"type":"tool_result","content":"noise"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"속마음"},{"type":"text","text":"네, 수정했습니다"},{"type":"tool_use","name":"Bash"}]}}
        \\{"type":"last-prompt","lastPrompt":"배포 스크립트 고쳐줘","leafUuid":"x"}
        \\
    ;
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("배포 스크립트 고쳐줘", owned.conversation.prompt);
    // thinking·tool_use가 아니라 text 블록이어야 한다 — 속마음이 사이드바에 뜨면 안 된다.
    try testing.expectEqualStrings("네, 수정했습니다", owned.conversation.reply);
    try testing.expectEqualStrings("/w/maru", owned.conversation.cwd);
}

test "parseClaudeTail: 자동 입력을 사용자 프롬프트로 착각하지 않는다" {
    // `type:"user"`인데 사람이 친 게 아닌 것들(백그라운드 알림·컨텍스트 요약 이어받기)만 있고 last-prompt가 없다.
    // 이때 프롬프트 줄은 **비어야** 한다 — 추측으로 자동 입력을 띄우느니 비우는 편이 낫다(계약 1).
    const tail =
        \\{"type":"user","message":{"role":"user","content":"<task-notification>백그라운드 완료</task-notification>"}}
        \\{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation"}}
        \\
    ;
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("", owned.conversation.prompt);
    try testing.expect(owned.conversation.isEmpty());
}

test "parseClaudeTail: 서브에이전트(sidechain) 응답을 배제한다" {
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"사용자 응답"}]}}
        \\{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"서브에이전트 내부"}]}}
        \\
    ;
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("사용자 응답", owned.conversation.reply);
}

test "parseClaudeTail: 잘린 줄·깨진 JSON·빈 입력에도 죽지 않는다(계약 1)" {
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, "", &owned);
    try testing.expect(owned.conversation.isEmpty());
    parseClaudeTail(testing.allocator, "{\"type\":\"last-prompt\",\"lastPro", &owned); // 중간에서 잘린 줄
    try testing.expect(owned.conversation.isEmpty());
    parseClaudeTail(testing.allocator, "not json at all\n{}\n[]\n", &owned);
    try testing.expect(owned.conversation.isEmpty());
    // type이 있어도 기대한 필드가 없으면 그냥 빈다.
    parseClaudeTail(testing.allocator, "{\"type\":\"last-prompt\"}\n{\"type\":\"assistant\",\"message\":{}}\n", &owned);
    try testing.expect(owned.conversation.isEmpty());
}

test "flatten: 여러 줄을 한 줄로 눕히고 UTF-8 경계를 지킨다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a b c", flatten("  a\n\n b\t\tc  ", &buf));
    // 버퍼가 한글 한 글자(3바이트) 중간에서 끝나면 그 글자를 통째로 버린다 — U+FFFD가 뜨지 않게.
    var tight: [4]u8 = undefined;
    try testing.expectEqualStrings("가", flatten("가나", &tight));
}

test "clampUtf8: 상한을 넘으면 글자 경계에서 자른다" {
    try testing.expectEqualStrings("가나", clampUtf8("가나", 6));
    try testing.expectEqualStrings("가나", clampUtf8("가나다", 8)); // 8바이트 = 2글자 + 2바이트 → 세 번째 글자를 버린다
    try testing.expectEqualStrings("ab", clampUtf8("abc", 2));
}

test "Owned.store: 상한을 넘겨도 넘치지 않고 앞부분을 남긴다" {
    var owned: Owned = .{};
    const long = "x" ** (max_text_bytes * 2);
    const kept = owned.store(long);
    try testing.expectEqual(max_text_bytes, kept.len);
}
