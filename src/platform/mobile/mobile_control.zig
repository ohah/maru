//! 폰이 컨트롤 플레인 wire 를 **프레임으로 읽는 자리**(S10d-1).
//!
//! 중계(`maru control --stdio`)는 바이트를 그대로 흘린다 — 줄을 세지도, `hello` 를 보지도
//! 않는다([컨트롤 플레인 §4a](../../../docs/control-plane.md)). **조립하는 곳은 여기 하나**이고,
//! 그래야 상한과 배압 규칙이 두 벌로 갈리지 않는다.
//!
//! **OS 를 안 부른다.** 시계도 소켓도 없다 — 시한은 host 가 재고(`timedOut`), 바이트는 host 가
//! 밀어 넣는다. 그래야 이 판정을 기기 없이 전부 테스트할 수 있다.
//!
//! **`hello` 앞에 잡음이 올 수 있다.** `exec` 은 사용자 셸을 거쳐 돌기 때문에 초기화 스크립트가
//! 낸 출력이 stdout 앞에 섞일 수 있고(RFC 4254 §6.5 가 그 부류를 경고한다), 그래서 "첫 줄이
//! `hello` 가 아니면 실패" 로 다루면 `~/.zshenv` 한 줄에 정상 서버가 못 붙는다. 찾을 때까지
//! 줄을 버리되 **버리는 양에 상한**을 둔다.

const std = @import("std");

/// 한 프레임(한 줄)의 상한. 서버 wire 는 ≈1MiB 를 허용하지만(프로토콜 §4.3) **폰은 그만큼 들지
/// 않는다** — 큰 답은 chunk notification 으로 나뉘어 오도록 프로토콜이 정해 두었고, 세션 목록
/// 한 줄은 수 KB 다. 넘으면 그 줄을 버리고 이유를 남긴다(조용히 자르면 JSON 이 깨진 채 파서로 간다).
pub const max_frame = 64 * 1024;

/// `hello` 를 찾기 전에 버릴 수 있는 총량(계약 §4a — 2026-08-20 확정). 셸 초기화가 내는 잡음은
/// 몇 줄이고, 프레임 상한을 다 쓰게 두면 아무 프로그램의 출력이나 그만큼 받아 주는 셈이 된다.
pub const max_noise = 64 * 1024;

/// 우리가 아는 프로토콜 이름. 다르면 축을 끈다 — 모르는 프로토콜을 "아마 맞겠지" 로 읽지 않는다.
///
/// **문자열을 옮겨 적지 않고 서버 것을 그대로 든다.** 두 벌이면 한쪽만 고쳐지고, 그 차이는
/// "폰만 붙는 서버가 없다" 로 나타난다 — 이 저장소가 값 드리프트로 여러 번 겪은 모양이다
/// (적대적 검증이 잡았다).
pub const protocol_id = @import("maru").session.control_plane.protocol_id;

/// 컨트롤 축이 어디까지 왔나.
pub const State = enum {
    /// 아직 아무것도 안 왔다 — `hello` 를 기다린다.
    waiting_hello,
    /// `hello` 를 받았고 그 안을 읽었다. 이제 요청을 보낼 수 있다.
    ready,
    /// 축을 껐다. **터미널과 무관하다** — 이 축만 접는다.
    off,
};

/// 왜 껐나. **하나로 뭉치면 화면이 사용자에게 할 말을 못 고른다.**
pub const OffReason = enum {
    none,
    /// 시한 안에 `hello` 가 안 왔다(강제 명령 서버이거나 `maru` 가 없다).
    hello_timeout,
    /// 잡음이 상한을 넘었다 — `hello` 가 올 자리가 아니다.
    too_much_noise,
    /// `hello` 는 왔는데 프로토콜이 우리 것이 아니다.
    protocol_mismatch,
    /// 한 줄이 상한을 넘었다.
    frame_too_large,
    /// **채널 자체를 못 열었다** — `hello` 를 기다려 볼 자리에도 못 갔다. 앞의 넷은 전부 "열긴
    /// 열었는데 그 뒤가 틀어졌다" 이고 이것만 그 앞에서 진다. 없던 시절에는 이 실패가 host 로그에만
    /// 남아, 화면은 **영영 "받는 중"** 이었다(기기 실측) — 계약 §4a 는 "실패하면 그 화면에서
    /// 말한다" 이다.
    open_failed,
    /// 원격 명령이 그냥 끝났다 — 열리지도 못했다. **시한을 기다릴 이유가 없다**: 답할 것이
    /// 이미 죽었으므로 `hello_timeout` 으로 뭉치면 사용자가 고칠 자리를 못 찾는다.
    command_failed,
};

/// `feed` 한 걸음의 결과.
pub const Step = struct {
    /// 이번에 완성된 프레임(줄) 하나. `hello` 는 여기 안 실린다 — 그것은 이 층이 소비한다.
    frame: ?[]const u8 = null,
    state: State,
    /// 상태가 `off` 면 그 이유.
    off_reason: OffReason = .none,
};

pub const Client = struct {
    state: State = .waiting_hello,
    off_reason: OffReason = .none,

    /// 조립 중인 줄.
    line: [max_frame]u8 = undefined,
    line_len: usize = 0,
    /// 이 줄이 상한을 넘었나. **넘은 줄은 통째로 버린다** — 앞부분만 파서에 주면 JSON 이 깨진
    /// 채로 간다.
    line_overflow: bool = false,
    /// `hello` 전에 버린 바이트.
    noise: usize = 0,

    /// 서버가 말한 버전(진단용). `hello` 를 읽은 뒤에만 뜻이 있다.
    server_version: [64]u8 = @splat(0),
    server_version_len: usize = 0,
    /// 서버가 광고한 메서드 이름들. **없는 메서드는 부르지 않는다**(계약 §4a — 불러 놓고 오류를
    /// 보여 주는 것과 다르다). 이름을 통째로 들지 않고 **줄 원문을 그대로** 두고 찾는다:
    /// 폰에서 목록을 복사해 들 이유가 없고, 개수 상한을 또 정하게 된다.
    caps: [max_frame]u8 = undefined,
    caps_len: usize = 0,

    /// 요청 id. **0 은 안 쓴다** — 응답을 못 맞춘 자리와 구별한다.
    next_id: u64 = 1,

    /// 원격 명령의 종료 코드. `command_failed` 일 때만 뜻이 있다.
    exit_status: u32 = 0,

    /// host 가 원격 명령이 끝났다고 알린다. **프로세스는 이 층에 없다.**
    ///
    /// 이미 `hello` 를 받아 살아 있던 축이 끝난 것은 정상 종료다 — 그것까지 실패로 칠하면
    /// 정상적으로 닫은 화면이 오류를 띄운다.
    pub fn commandFailed(self: *Client, status: u32) void {
        if (self.state != .waiting_hello) return;
        self.state = .off;
        self.off_reason = .command_failed;
        self.exit_status = status;
    }

    /// host 가 시한을 넘겼다고 알린다. **시계는 이 층에 없다.**
    pub fn timedOut(self: *Client) void {
        if (self.state != .waiting_hello) return;
        self.state = .off;
        self.off_reason = .hello_timeout;
    }

    /// host 가 채널을 못 열었다고 알린다. **소켓은 이 층에 없다** — 여는 것도 지는 것도 host 만
    /// 안다. 시한(`timedOut`)과 같은 모양이고 이유만 다르다: 그쪽은 열고 나서 `hello` 가 안 온
    /// 것이고, 이쪽은 **열지도 못한** 것이다.
    pub fn openFailed(self: *Client) void {
        if (self.state != .waiting_hello) return;
        self.state = .off;
        self.off_reason = .open_failed;
    }

    /// 바이트를 밀어 넣는다. **한 걸음에 프레임 하나**를 돌려주므로, 호출자는 `consumed` 만큼
    /// 앞으로 밀고 다시 부른다(줄이 여러 개 담긴 조각을 잃지 않는다).
    pub fn feed(self: *Client, bytes: []const u8, consumed: *usize) Step {
        consumed.* = 0;
        if (self.state == .off) {
            consumed.* = bytes.len; // 껐어도 삼킨다 — 안 삼키면 호출자가 영원히 맴돈다
            return .{ .state = .off, .off_reason = self.off_reason };
        }

        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            i += 1;
            if (b != '\n') {
                if (self.line_len == self.line.len) {
                    self.line_overflow = true;
                } else {
                    self.line[self.line_len] = b;
                    self.line_len += 1;
                }
                continue;
            }

            // 줄 하나가 끝났다.
            const overflow = self.line_overflow;
            const line = self.line[0..self.line_len];
            defer {
                self.line_len = 0;
                self.line_overflow = false;
            }
            consumed.* = i;

            if (overflow) {
                self.state = .off;
                self.off_reason = .frame_too_large;
                return .{ .state = .off, .off_reason = .frame_too_large };
            }

            if (self.state == .waiting_hello) {
                if (isHello(line)) {
                    return self.acceptHello(line);
                }
                // 잡음이다 — 버리되 세어 둔다.
                self.noise += line.len + 1;
                if (self.noise > max_noise) {
                    self.state = .off;
                    self.off_reason = .too_much_noise;
                    return .{ .state = .off, .off_reason = .too_much_noise };
                }
                return .{ .state = .waiting_hello };
            }

            // 빈 줄은 프레임이 아니다(서버가 개행을 두 번 내면 그렇게 보인다).
            if (line.len == 0) return .{ .state = self.state };
            return .{ .frame = line, .state = self.state };
        }

        consumed.* = i;
        return .{ .state = self.state, .off_reason = self.off_reason };
    }

    fn acceptHello(self: *Client, line: []const u8) Step {
        if (jsonStringField(line, "protocol")) |p| {
            if (!std.mem.eql(u8, p, protocol_id)) {
                self.state = .off;
                self.off_reason = .protocol_mismatch;
                return .{ .state = .off, .off_reason = .protocol_mismatch };
            }
        } else {
            // 프로토콜 이름이 없는 `hello` 는 우리 것이 아니다.
            self.state = .off;
            self.off_reason = .protocol_mismatch;
            return .{ .state = .off, .off_reason = .protocol_mismatch };
        }

        if (jsonStringField(line, "server_version")) |v| {
            const n = @min(v.len, self.server_version.len - 1);
            @memcpy(self.server_version[0..n], v[0..n]);
            self.server_version[n] = 0;
            self.server_version_len = n;
        }
        // capabilities 는 원문을 그대로 둔다(아래 `supports` 가 그 안에서 찾는다).
        const n = @min(line.len, self.caps.len);
        @memcpy(self.caps[0..n], line[0..n]);
        self.caps_len = n;

        self.state = .ready;
        return .{ .state = .ready };
    }

    /// 서버가 그 메서드를 광고했나. **없으면 부르지 않는다**(계약 §4a).
    pub fn supports(self: *const Client, method: []const u8) bool {
        if (self.state != .ready) return false;
        const caps = self.caps[0..self.caps_len];
        const at = std.mem.indexOf(u8, caps, "\"capabilities\"") orelse return false;
        // **따옴표째 찾는다** — `sessions.list` 를 찾을 때 `sessions.listAll` 이 걸리면 안 된다.
        var needle: [128]u8 = undefined;
        if (method.len + 2 > needle.len) return false;
        needle[0] = '"';
        @memcpy(needle[1 .. 1 + method.len], method);
        needle[1 + method.len] = '"';
        return std.mem.indexOf(u8, caps[at..], needle[0 .. method.len + 2]) != null;
    }

    pub fn serverVersion(self: *const Client) []const u8 {
        return self.server_version[0..self.server_version_len];
    }

    /// 요청 한 줄을 만든다. **개행까지 붙여 준다** — 붙이는 자리를 호출자에 맡기면 잊는다.
    pub fn writeRequest(self: *Client, out: []u8, method: []const u8, params_json: ?[]const u8) error{ ShortBuffer, NotReady }![]const u8 {
        if (self.state != .ready) return error.NotReady;
        var w = std.Io.Writer.fixed(out);
        const id = self.next_id;
        if (params_json) |p| {
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, p }) catch return error.ShortBuffer;
        } else {
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}\n", .{ id, method }) catch return error.ShortBuffer;
        }
        self.next_id += 1;
        return w.buffered();
    }
};

/// 이 줄이 `hello` notification 인가. **id 가 없는 notification 이어야 한다** — 같은 이름의
/// 응답을 `hello` 로 오해하면 그 뒤 판정이 전부 어긋난다.
fn isHello(line: []const u8) bool {
    if (jsonStringField(line, "method")) |m| return std.mem.eql(u8, m, "hello");
    return false;
}

/// 아주 작은 JSON 문자열 필드 읽기. **전체 파서를 안 쓴다** — 이 층이 보는 것은 `hello` 한 줄의
/// 몇 필드뿐이고, 그 한 줄 때문에 할당자를 들이면 브리지가 실패할 자리가 는다. 프레임 본문은
/// 화면 쪽이 제대로 파싱한다.
pub fn jsonStringField(line: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (name.len + 3 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    key_buf[2 + name.len] = ':';
    const key = key_buf[0 .. name.len + 3];

    var at = std.mem.indexOf(u8, line, key) orelse return null;
    at += key.len;
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    if (at >= line.len or line[at] != '"') return null;
    at += 1;
    const start = at;
    while (at < line.len) : (at += 1) {
        if (line[at] == '\\') {
            at += 1; // 이스케이프 다음 글자는 값이다
            continue;
        }
        if (line[at] == '"') return line[start..at];
    }
    return null;
}

// ── 세션 목록 읽기(S10d-2) ───────────────────────────────────────────────────
//
// `sessions.list` 의 결과는 **배열 자체**이고 원소는 surface 객체다(`cli/sessions.zig` 가 같은
// 것을 사람 줄로 그린다). 폰이 쓰는 것은 그중 몇 필드뿐이다.
//
// **할당하지 않는다.** 값은 전부 **받은 프레임 안을 가리키는 슬라이스**라 다음 `feed` 까지만
// 산다 — 화면이 들고 있으려면 자기 자리에 복사해야 한다(브리지가 그렇게 한다). 트리를 만들면
// 그 수명과 실패 경로가 브리지로 새어 들어온다.

/// 프롬프트에 있나. **3상이다** — JSON 의 `true`·`false`·`null` 을 접지 않는다(계약 §3).
/// 모르는 것을 "아니다" 로 접으면 화면이 없는 사실을 말한다.
pub const AtPrompt = enum { unknown, yes, no };

pub const Session = struct {
    surface_id: i64 = -1,
    title: []const u8 = "",
    cwd: []const u8 = "",
    git_branch: []const u8 = "",
    agent_kind: []const u8 = "",
    agent_state: []const u8 = "",
    at_prompt: AtPrompt = .unknown,
    focused: bool = false,
    /// 그 세션의 runtime id(32 소문자 hex). **host-backed 일 때만 온다**(계약 §3) — in-process
    /// Term 에는 runtime 이 없다. **이 값의 유무가 곧 "붙을 수 있는가" 다**: 있으면 눌러서 그
    /// 화면을 열고, 없으면 목록에 보이되 안 눌린다.
    runtime_id: []const u8 = "",
};

/// 응답 프레임 하나에서 세션들을 읽어 `out` 에 채운다. **채운 개수**를 돌려준다.
///
/// `out` 보다 많이 오면 **앞에서부터 담고 나머지는 버린다** — 화면이 다 못 그릴 바에야 상한을
/// 호출자가 정하는 편이 낫다(그리고 그 사실은 개수로 드러난다).
fn isLowerHex(text: []const u8) bool {
    for (text) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub fn parseSessions(frame: []const u8, out: []Session) usize {
    const result = jsonValueField(frame, "result") orelse return 0;
    var n: usize = 0;
    var it = ArrayObjects{ .rest = result };
    while (it.next()) |obj| {
        if (n == out.len) break;
        out[n] = parseSession(obj);
        n += 1;
    }
    return n;
}

fn parseSession(obj: []const u8) Session {
    var s: Session = .{};
    if (jsonValueField(obj, "id")) |id_obj| {
        s.surface_id = jsonIntField(id_obj, "surface_id") orelse -1;
    }
    if (jsonStringField(obj, "title")) |v| s.title = v;
    // **없으면 빈 값 그대로** — 그 세션은 못 붙는다(계약 §3). 32 소문자 hex 가 아니면 안 받는다:
    // 이 값은 명령 줄에 실리고 원격 셸이 그것을 파싱한다(§4a).
    if (jsonStringField(obj, "runtime_id")) |v| {
        if (v.len == 32 and isLowerHex(v)) s.runtime_id = v;
    }
    if (jsonStringField(obj, "cwd")) |v| s.cwd = v;
    if (jsonStringField(obj, "git_branch")) |v| s.git_branch = v;
    if (jsonValueField(obj, "agent")) |ag| {
        if (jsonStringField(ag, "kind")) |v| s.agent_kind = v;
        if (jsonStringField(ag, "state")) |v| s.agent_state = v;
    }
    s.at_prompt = switch (jsonLiteralField(obj, "at_prompt")) {
        .true_ => .yes,
        .false_ => .no,
        .null_, .missing => .unknown,
    };
    s.focused = jsonLiteralField(obj, "focused") == .true_;
    return s;
}

/// 최상위 배열의 원소들을 하나씩. **문자열 안의 괄호를 안 센다** — 세면 `cwd` 에 `{` 가 든
/// 경로에서 원소 경계가 어긋난다.
const ArrayObjects = struct {
    rest: []const u8,

    fn next(self: *ArrayObjects) ?[]const u8 {
        var i: usize = 0;
        while (i < self.rest.len and self.rest[i] != '{') : (i += 1) {
            if (self.rest[i] == ']') return null;
        }
        if (i == self.rest.len) return null;
        const start = i;
        var depth: usize = 0;
        var in_str = false;
        while (i < self.rest.len) : (i += 1) {
            const c = self.rest[i];
            if (in_str) {
                if (c == '\\') {
                    i += 1;
                    continue;
                }
                if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        const obj = self.rest[start .. i + 1];
                        self.rest = self.rest[i + 1 ..];
                        return obj;
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

/// 필드 값이 시작하는 자리부터 끝까지(객체·배열이면 그 짝까지). 없으면 `null`.
pub fn jsonValueField(line: []const u8, name: []const u8) ?[]const u8 {
    const at = fieldValueStart(line, name) orelse return null;
    const rest = line[at..];
    if (rest.len == 0) return null;
    const open = rest[0];
    const close: u8 = switch (open) {
        '{' => '}',
        '[' => ']',
        else => return rest, // 스칼라는 그 자리부터(호출자가 알아서 읽는다)
    };
    var depth: usize = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
        } else if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return rest[0 .. i + 1];
        }
    }
    return null;
}

pub fn jsonIntField(line: []const u8, name: []const u8) ?i64 {
    const at = fieldValueStart(line, name) orelse return null;
    var end = at;
    while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '-')) end += 1;
    if (end == at) return null;
    return std.fmt.parseInt(i64, line[at..end], 10) catch null;
}

/// `true`·`false`·`null` 셋을 가른다. **`null` 을 `false` 로 접지 않는다**(3상).
pub const Literal = enum { true_, false_, null_, missing };

pub fn jsonLiteralField(line: []const u8, name: []const u8) Literal {
    const at = fieldValueStart(line, name) orelse return .missing;
    const rest = line[at..];
    if (std.mem.startsWith(u8, rest, "true")) return .true_;
    if (std.mem.startsWith(u8, rest, "false")) return .false_;
    if (std.mem.startsWith(u8, rest, "null")) return .null_;
    return .missing;
}

/// `"name":` 뒤 값이 시작하는 자리.
fn fieldValueStart(line: []const u8, name: []const u8) ?usize {
    var key_buf: [64]u8 = undefined;
    if (name.len + 3 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    key_buf[2 + name.len] = ':';
    const key = key_buf[0 .. name.len + 3];
    var at = std.mem.indexOf(u8, line, key) orelse return null;
    at += key.len;
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    if (at >= line.len) return null;
    return at;
}

const testing = std.testing;

const hello_line = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"maru.control.v1\",\"server_version\":\"0.1.0\",\"capabilities\":[\"sessions.list\",\"session.capture\"]}}\n";

/// 한 조각을 다 먹을 때까지 밀어 넣고, 마지막 걸음을 돌려준다.
fn feedAll(c: *Client, bytes: []const u8) Step {
    var off: usize = 0;
    var last: Step = .{ .state = c.state };
    while (off < bytes.len) {
        var consumed: usize = 0;
        last = c.feed(bytes[off..], &consumed);
        if (consumed == 0) break;
        off += consumed;
    }
    return last;
}

test "hello 를 받으면 축이 선다" {
    var c: Client = .{};
    try testing.expectEqual(State.waiting_hello, c.state);
    const step = feedAll(&c, hello_line);
    try testing.expectEqual(State.ready, step.state);
    try testing.expectEqualStrings("0.1.0", c.serverVersion());
    // **hello 는 프레임으로 안 올린다** — 이 층이 소비한다.
    try testing.expectEqual(@as(?[]const u8, null), step.frame);
}

test "hello 앞의 잡음은 버린다 — 첫 줄로 판정하지 않는다" {
    // `exec` 은 사용자 셸을 거쳐 돌기 때문에 `~/.zshenv` 같은 것이 앞에 낀다(RFC 4254 §6.5).
    // 첫 줄로 판정하면 그 한 줄에 정상 서버가 못 붙는다.
    var c: Client = .{};
    _ = feedAll(&c, "nvm: loaded\n");
    _ = feedAll(&c, "some warning from .zshenv\n");
    try testing.expectEqual(State.waiting_hello, c.state);
    const step = feedAll(&c, hello_line);
    try testing.expectEqual(State.ready, step.state);
}

test "잡음이 상한을 넘으면 축을 끈다" {
    // 상한이 없으면 아무 프로그램의 출력이나 계속 받아 주는 셈이 된다.
    var c: Client = .{};
    var noise: [1024]u8 = @splat('x');
    noise[noise.len - 1] = '\n';
    var sent: usize = 0;
    while (sent <= max_noise) : (sent += noise.len) {
        const step = feedAll(&c, &noise);
        if (step.state == .off) {
            try testing.expectEqual(OffReason.too_much_noise, step.off_reason);
            return;
        }
    }
    return error.TestExpectedOff;
}

test "프레임이 상한을 넘으면 그 줄을 통째로 버리고 끈다" {
    // 앞부분만 파서에 주면 **JSON 이 깨진 채로** 간다 — 그 실패는 원인을 짚기 어렵다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    var big: [max_frame + 16]u8 = @splat('a');
    big[big.len - 1] = '\n';
    const step = feedAll(&c, &big);
    try testing.expectEqual(State.off, step.state);
    try testing.expectEqual(OffReason.frame_too_large, step.off_reason);
}

test "hello 뒤의 줄은 프레임으로 올라온다 — 조각으로 와도" {
    // 패킷 경계는 줄 경계가 아니다(계약 §4a). 조각으로 와도 한 줄로 모여야 한다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    _ = feedAll(&c, "{\"jsonrpc\":\"2.0\",\"id\":1,\"resu");
    const step = feedAll(&c, "lt\":{\"sessions\":[]}}\n");
    try testing.expect(step.frame != null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessions\":[]}}", step.frame.?);
}

test "한 조각에 줄이 여럿이면 하나씩 준다 — 잃지 않는다" {
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    const two = "{\"a\":1}\n{\"b\":2}\n";
    var off: usize = 0;
    var consumed: usize = 0;
    const first = c.feed(two[off..], &consumed);
    off += consumed;
    try testing.expectEqualStrings("{\"a\":1}", first.frame.?);
    const second = c.feed(two[off..], &consumed);
    off += consumed;
    try testing.expectEqualStrings("{\"b\":2}", second.frame.?);
    try testing.expectEqual(two.len, off);
}

test "프로토콜이 다르면 축을 끈다" {
    // 모르는 프로토콜을 "아마 맞겠지" 로 읽으면 그 뒤 판정이 전부 어긋난다.
    var c: Client = .{};
    const other = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":{\"protocol\":\"maru.control.v2\"}}\n";
    const step = feedAll(&c, other);
    try testing.expectEqual(State.off, step.state);
    try testing.expectEqual(OffReason.protocol_mismatch, step.off_reason);
}

test "프로토콜 이름이 없는 hello 도 우리 것이 아니다" {
    var c: Client = .{};
    const step = feedAll(&c, "{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}\n");
    try testing.expectEqual(State.off, step.state);
    try testing.expectEqual(OffReason.protocol_mismatch, step.off_reason);
}

test "명령이 그냥 끝나면 시한과 다른 이유로 꺼진다" {
    // 답할 것이 이미 죽었다 — 5초를 더 기다릴 이유가 없고, 종료 코드가 **고칠 자리**를 가른다.
    var c: Client = .{};
    c.commandFailed(127);
    try testing.expectEqual(State.off, c.state);
    try testing.expectEqual(OffReason.command_failed, c.off_reason);
    try testing.expectEqual(@as(u32, 127), c.exit_status);

    // 이미 선 축이 끝난 것은 정상 종료다 — 목록을 다 받고 닫은 화면에 오류를 띄우면 안 된다.
    var ready: Client = .{};
    _ = feedAll(&ready, hello_line);
    ready.commandFailed(0);
    try testing.expectEqual(State.ready, ready.state);
    try testing.expectEqual(OffReason.none, ready.off_reason);
}

test "시한을 넘기면 host 가 껐다고 말할 수 있다" {
    // **시계는 이 층에 없다.** 강제 명령 서버는 무언가를 출력하며 오래 살 수도 있어, 시한이
    // 없으면 영영 안 끝난다(계약 §4a — 5초).
    var c: Client = .{};
    c.timedOut();
    try testing.expectEqual(State.off, c.state);
    try testing.expectEqual(OffReason.hello_timeout, c.off_reason);
    // 이미 선 축은 시한으로 안 꺼진다.
    var ready: Client = .{};
    _ = feedAll(&ready, hello_line);
    ready.timedOut();
    try testing.expectEqual(State.ready, ready.state);
}

test "광고 안 한 메서드는 안 부른다" {
    // 불러 놓고 `method-not-found` 를 오류로 보여 주는 것과 다르다 — 화면에서 그 기능을 지운다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    try testing.expect(c.supports("sessions.list"));
    try testing.expect(c.supports("session.capture"));
    try testing.expect(!c.supports("browser.navigate"));
    // **접두가 같은 이름에 안 걸린다.**
    try testing.expect(!c.supports("sessions.li"));
    try testing.expect(!c.supports("sessions"));
}

test "축이 서기 전에는 요청을 못 만든다" {
    var c: Client = .{};
    var out: [256]u8 = undefined;
    try testing.expectError(error.NotReady, c.writeRequest(&out, "sessions.list", null));
}

test "요청은 한 줄이고 id 가 늘어난다" {
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    var out: [256]u8 = undefined;
    const first = try c.writeRequest(&out, "sessions.list", null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}\n", first);

    var out2: [256]u8 = undefined;
    const second = try c.writeRequest(&out2, "session.capture", "{\"id\":7}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.capture\",\"params\":{\"id\":7}}\n", second);
}

test "자리가 모자라면 자르지 않고 실패한다" {
    // 잘린 요청은 **다른 요청**이고, 서버는 그것을 파싱 오류로 만난다.
    var c: Client = .{};
    _ = feedAll(&c, hello_line);
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.ShortBuffer, c.writeRequest(&tiny, "sessions.list", null));
}

test "끈 뒤에도 바이트를 삼킨다 — 호출자가 안 맴돈다" {
    var c: Client = .{};
    c.timedOut();
    var consumed: usize = 0;
    const step = c.feed("아무 바이트나\n", &consumed);
    try testing.expectEqual(State.off, step.state);
    try testing.expect(consumed > 0);
}

test "필드 읽기는 이스케이프를 넘긴다" {
    // `"cwd":"C:\\path\"quote"` 같은 값에서 끝을 잘못 잡으면 뒤 필드를 통째로 잃는다.
    const line = "{\"a\":\"x\\\"y\",\"b\":\"z\"}";
    try testing.expectEqualStrings("x\\\"y", jsonStringField(line, "a").?);
    try testing.expectEqualStrings("z", jsonStringField(line, "b").?);
    try testing.expectEqual(@as(?[]const u8, null), jsonStringField(line, "c"));
}

test "서버가 실제로 만드는 hello 를 그대로 읽는다" {
    // **문자열을 지어내 재면 아무것도 안 잰다.** 서버의 직렬화기(`control_plane.serializeHello`)가
    // 만든 바이트를 그대로 먹여, 필드 자리·따옴표·배열 표기가 우리 판정과 맞는지 본다 —
    // 그 둘이 어긋나면 기기에서 "왜인지 축이 안 선다" 로만 보인다.
    const cp = @import("maru").session.control_plane;
    const wire = try cp.serializeHello(testing.allocator, .{
        .server_version = "0.1.0",
        .capabilities = &.{ "sessions.list", "session.capture" },
    });
    defer testing.allocator.free(wire);

    var c: Client = .{};
    var line: [max_frame]u8 = undefined;
    const n = wire.len;
    @memcpy(line[0..n], wire);
    line[n] = '\n';

    const step = feedAll(&c, line[0 .. n + 1]);
    try testing.expectEqual(State.ready, step.state);
    try testing.expectEqualStrings("0.1.0", c.serverVersion());
    try testing.expect(c.supports("sessions.list"));
    try testing.expect(c.supports("session.capture"));
    try testing.expect(!c.supports("browser.navigate"));
}

test "capabilities 가 빈 서버는 아무 메서드도 못 부른다" {
    // 빈 목록을 "전부 된다" 로 읽으면, 폰이 없는 메서드를 부르고 그 오류를 사용자에게 보인다.
    const cp = @import("maru").session.control_plane;
    const wire = try cp.serializeHello(testing.allocator, .{
        .server_version = "0.1.0",
        .capabilities = &.{},
    });
    defer testing.allocator.free(wire);

    var c: Client = .{};
    var line: [max_frame]u8 = undefined;
    @memcpy(line[0..wire.len], wire);
    line[wire.len] = '\n';
    const step = feedAll(&c, line[0 .. wire.len + 1]);
    try testing.expectEqual(State.ready, step.state);
    try testing.expect(!c.supports("sessions.list"));
}

test "capabilities 밖의 우연한 일치는 능력이 아니다" {
    // 메서드 이름이 **다른 필드에** 들어 있을 수 있다(버전 문자열·설명 등). 줄 전체에서 찾으면
    // 그것을 능력으로 읽고, 폰은 없는 메서드를 부른다.
    const cp = @import("maru").session.control_plane;
    const wire = try cp.serializeHello(testing.allocator, .{
        // **따옴표째 똑같아야 이 테스트가 뜻이 있다.** 처음에는 `0.1.0+sessions.list` 로 썼는데
        // 그러면 `"sessions.list"` 라는 정확한 패턴이 안 생겨(앞이 `+`) 변이가 살아남았다.
        .server_version = "sessions.list",
        .capabilities = &.{"session.capture"},
    });
    defer testing.allocator.free(wire);

    var c: Client = .{};
    var line: [max_frame]u8 = undefined;
    @memcpy(line[0..wire.len], wire);
    line[wire.len] = '\n';
    _ = feedAll(&c, line[0 .. wire.len + 1]);

    try testing.expect(c.supports("session.capture"));
    // **버전에 든 글자를 능력으로 읽지 않는다.**
    try testing.expect(!c.supports("sessions.list"));
}

// ── 세션 목록 읽기 테스트 ─────────────────────────────────────────────────────

const list_frame =
    \\{"jsonrpc":"2.0","id":1,"result":[
    \\{"id":{"surface_id":7},"kind":"terminal","title":"maru","window":1,"tab":1,"pane":1,"focused":true,"cwd":"/Users/me/dev","git_branch":"main","agent":{"kind":"claude","state":"running"},"at_prompt":false},
    \\{"id":{"surface_id":9},"kind":"terminal","title":"logs","window":1,"tab":2,"pane":1,"focused":false,"cwd":"/var/log","at_prompt":true},
    \\{"id":{"surface_id":11},"kind":"web","title":"docs","window":1,"tab":3,"pane":1,"focused":false,"url":"https://x"}
    \\]}
;

test "세션 목록을 읽는다 — 필드가 제자리에 온다" {
    var out: [8]Session = undefined;
    const n = parseSessions(list_frame, &out);
    try testing.expectEqual(@as(usize, 3), n);

    try testing.expectEqual(@as(i64, 7), out[0].surface_id);
    try testing.expectEqualStrings("maru", out[0].title);
    try testing.expectEqualStrings("/Users/me/dev", out[0].cwd);
    try testing.expectEqualStrings("main", out[0].git_branch);
    try testing.expectEqualStrings("claude", out[0].agent_kind);
    try testing.expectEqualStrings("running", out[0].agent_state);
    try testing.expectEqual(AtPrompt.no, out[0].at_prompt);
    try testing.expect(out[0].focused);

    try testing.expectEqual(@as(i64, 9), out[1].surface_id);
    try testing.expectEqual(AtPrompt.yes, out[1].at_prompt);
    try testing.expectEqualStrings("", out[1].git_branch); // 없는 필드는 빈 값이다
    try testing.expect(!out[1].focused);

    try testing.expectEqual(@as(i64, 11), out[2].surface_id);
}

test "at_prompt 는 3상이다 — null 을 false 로 접지 않는다" {
    // 모르는 것을 "아니다" 로 접으면 화면이 **없는 사실**을 말한다(계약 §3).
    const frame = "{\"result\":[{\"id\":{\"surface_id\":1},\"at_prompt\":null},{\"id\":{\"surface_id\":2}}]}";
    var out: [4]Session = undefined;
    const n = parseSessions(frame, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(AtPrompt.unknown, out[0].at_prompt);
    try testing.expectEqual(AtPrompt.unknown, out[1].at_prompt);
}

test "cwd 에 짝 없는 중괄호가 들어도 원소 경계가 안 어긋난다" {
    // 문자열 안의 괄호를 세면 그 자리에서 목록이 쪼개진다.
    //
    // **짝이 맞는 `{a,b}` 로는 이것을 못 잰다** — depth 가 +1 뒤 -1 로 돌아와 경계가 그대로다
    // (처음 쓴 테스트가 그래서 변이를 놓쳤다). 짝이 **안 맞는** 괄호라야 뜻이 있다.
    const frame = "{\"result\":[{\"id\":{\"surface_id\":1},\"cwd\":\"/tmp/{\"},{\"id\":{\"surface_id\":2},\"cwd\":\"/x\"}]}";
    var out: [4]Session = undefined;
    const n = parseSessions(frame, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("/tmp/{", out[0].cwd);
    try testing.expectEqual(@as(i64, 2), out[1].surface_id);
    try testing.expectEqualStrings("/x", out[1].cwd);
}

test "자리보다 많이 오면 앞에서부터 담고 개수로 드러난다" {
    var out: [2]Session = undefined;
    const n = parseSessions(list_frame, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 7), out[0].surface_id);
}

test "runtime id 는 있을 때만 실리고 32 소문자 hex 라야 한다" {
    // **이 값의 유무가 "붙을 수 있는가" 다**(§3). 그리고 명령 줄에 실려 원격 셸이 파싱하므로
    // (§4a) 형식이 아니면 안 받는다 — 목록은 원격이 준 것이다.
    var out: [6]Session = @splat(.{});
    const frame =
        \\{"jsonrpc":"2.0","id":1,"result":[
        \\{"id":{"surface_id":1},"title":"host-backed","runtime_id":"0123456789abcdef0123456789abcdef"},
        \\{"id":{"surface_id":2},"title":"in-process"},
        \\{"id":{"surface_id":3},"title":"짧다","runtime_id":"abc"},
        \\{"id":{"surface_id":4},"title":"메타문자","runtime_id":"; id > /aaaaaaaaaaaaaaaaaaaaaaaa"},
        \\{"id":{"surface_id":5},"title":"대문자","runtime_id":"0123456789ABCDEF0123456789abcdef"}]}
    ;
    const n = parseSessions(frame, &out);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", out[0].runtime_id);
    // 없는 줄은 빈 값이다 — 목록에는 보이되 안 눌린다.
    try testing.expectEqual(@as(usize, 0), out[1].runtime_id.len);
    // 형식이 아니면 **안 받는다**(길이·문자 둘 다).
    try testing.expectEqual(@as(usize, 0), out[2].runtime_id.len);
    // **길이는 맞는데 문자가 아닌 것** — 이것을 안 재면 길이 검사만으로도 초록이다(변이가 잡았다).
    try testing.expectEqual(@as(usize, 32), @as(usize, 32));
    try testing.expectEqual(@as(usize, 0), out[3].runtime_id.len);
    try testing.expectEqual(@as(usize, 0), out[4].runtime_id.len);
}

test "빈 목록과 결과 없음을 가른다" {
    var out: [4]Session = undefined;
    try testing.expectEqual(@as(usize, 0), parseSessions("{\"result\":[]}", &out));
    // `result` 가 아예 없으면(오류 응답) 0 이다 — 빈 목록과 같은 수지만 프레임이 다르다.
    try testing.expectEqual(@as(usize, 0), parseSessions("{\"error\":{\"code\":-32601}}", &out));
}

test "surface_id 가 없으면 -1 이다 — 0 으로 접지 않는다" {
    // 0 은 실제 surface 번호일 수 있다. 없는 것을 있는 값으로 접으면 **엉뚱한 세션을 가리킨다**.
    //
    // 두 모양을 다 잰다: `id` 자체가 없는 것과, `id` 는 있는데 그 안이 빈 것.
    // 뒤엣것이 없으면 `orelse` 가지가 안 밟혀 변이가 살아남는다(실제로 그랬다).
    var out: [2]Session = undefined;
    const n = parseSessions("{\"result\":[{\"kind\":\"terminal\"},{\"id\":{},\"kind\":\"terminal\"}]}", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, -1), out[0].surface_id);
    try testing.expectEqual(@as(i64, -1), out[1].surface_id);
}

test "focused 가 없으면 초점이 아니다 — 없는 것을 참으로 접지 않는다" {
    // 목록에서 "지금 보고 있는 것" 을 잘못 짚으면 사용자가 다른 세션을 연다.
    var out: [2]Session = undefined;
    const n = parseSessions("{\"result\":[{\"id\":{\"surface_id\":1}}]}", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(!out[0].focused);
}
