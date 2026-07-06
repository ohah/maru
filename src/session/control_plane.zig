//! control_plane — 세션 컨트롤 플레인 wire 프로토콜의 L2 순수 코어 (schema/parser/framing/error-model).
//! Track C slice 1a. 단일 출처: docs/control-plane.md §1·§4.1·§4.3·§10·§16.
//!
//! **베이스와 결정(clean-room, docs/control-plane.md §10):**
//! - **메커니즘 = JSON-RPC 2.0** over 로컬 socket(LSP/DAP/CDP가 공유하는 그 메커니즘만 빌린다). request/response는
//!   `id`로 매칭하고, `id`가 없는 message는 notification이다(§1). LSP의 어휘(textDocument/*)는 채택하지 않는다.
//! - **프레이밍 = ndjson**(§1·§4.3): message 1개 = 1줄. 직렬화는 JSON 단독(std.json), 의존성 0. 대형 payload chunk
//!   (§4.3)와 base64는 1f(capture) slice 소관이라 여기 없다 — 이 파일은 "바이트↔message + 줄 프레이밍 + 에러 모델"만.
//!
//! **범위(1a, 소켓 0):** message 스키마 parse/serialize, JSON-RPC 에러 코드 모델, ndjson 프레이머(부분읽기 누적 +
//! max-frame 게이트), `hello` notification 스키마, method 네임스페이스 파싱. **범위 밖:** unix socket bind/accept/
//! peer-cred(1b), 실제 dispatch·handler(1c+), capability/auth(1e), collector·surface 상태(1c+).
//!
//! **L2 순수:** std만 import한다(app/pty/platform import 0 — tests/boundary/imports.zig가 강제). OS 타입 0.
//!
//! **payload 표현 결정:** request `params`, response `result`, error `data`는 dispatch(후속 slice)가 해석하는
//! **불투명 JSON**이라 여기선 `std.json.Value`로 그대로 담는다(스키마를 미리 못박지 않는다 — §4.1 "닫힌 하드코딩
//! 테이블이 아니다"). 그래서 parse 결과(`ParsedMessage`)는 std.json arena를 소유하고(`deinit` 필수), 그 안의
//! 슬라이스·Value는 arena 수명에 묶인다(agent_transcript.zig의 parseFromSlice(Value) 패턴과 동일).
//!
//! **alloc 전략 결정(범위 애매점 보고 대상):** std.json.parseFromSlice가 arena 소유를 강요하므로, parse는
//! `gpa`를 받아 arena를 소유한 `ParsedMessage`를 돌려주고 caller가 `deinit`한다(leaky 변형은 두지 않는다 — 컨트롤
//! 플레인은 frame당 parse→dispatch→free 수명이라 소유 wrapper가 자연스럽다). serialize도 `gpa`를 받아 소유
//! 슬라이스를 돌려준다(streaming std.json.Stringify → Allocating writer). 둘 다 최소 선택이며 소켓 buffer 전략은 1b.

const std = @import("std");

// ── 상수 ──────────────────────────────────────────────────────────────────────────────────────────────────
/// JSON-RPC 2.0 version 태그. 모든 message의 `jsonrpc` 필드는 정확히 이 값이어야 한다(§10).
pub const jsonrpc_version = "2.0";
/// 핸드셰이크가 광고하는 프로토콜 식별자(docs/control-plane.md §4.1). 버전 skew 감지에 쓴다.
pub const protocol_id = "maru.control.v1";
/// `hello` notification의 method 이름(§4.1).
pub const hello_method = "hello";
/// max frame 크기(≈ 1 MiB, §4.3). "frame 크기" = 종단 `\n`을 제외한 한 줄의 바이트 수(선행 `\r`이 있으면 포함).
pub const default_max_frame: usize = 1024 * 1024;

// ── 에러 모델(JSON-RPC 2.0 §5.1 + maru 확장 §4.3) ─────────────────────────────────────────────────────────
/// 표준 JSON-RPC 2.0 에러 코드 + maru 확장. `RpcError.code`는 임의 i64를 담으므로(후속 slice의 앱-정의 코드도
/// 표현), 이 enum은 1a가 실제로 다루는 **알려진** 코드의 편의 상수다. -32000~-32099는 JSON-RPC이 impl-defined
/// server-error로 예약한 범위라 maru 확장을 거기에 둔다.
pub const ErrorCode = enum(i64) {
    parse_error = -32700, // 잘못된 JSON(바이트 수준) — 서버가 payload를 파싱 못 함.
    invalid_request = -32600, // 유효한 JSON이나 유효한 Request 객체가 아님.
    method_not_found = -32601, // 메서드 부재/미가용(dispatch — 후속 slice).
    invalid_params = -32602, // 잘못된 메서드 파라미터(dispatch — 후속 slice).
    internal_error = -32603, // 내부 서버 오류.
    // ── maru 확장(§4.3) ──
    /// frame이 max frame 크기를 초과(§4.3). 프레이머가 알리고, 소켓 계층(1b)이 연결을 종료한다. 코드값 -32001은
    /// impl-defined server-error 범위에서 maru가 택한 값(docs/document-basis-and-decision — 명세가 번호를 정하지
    /// 않아 우리가 고정). 문서에는 payload-too-large라는 이름만 있고 번호는 미지정이었다.
    payload_too_large = -32001,

    /// 이 코드의 표준 짧은 message(JSON-RPC §5.1의 관례). 에러 응답 build 편의.
    pub fn defaultMessage(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
            .payload_too_large => "Payload too large",
        };
    }
};

/// JSON-RPC 에러 객체 `{code, message, data?}`(§5.1). `code`는 raw i64라 표준/확장/앱-정의 코드를 모두 표현한다.
/// `data`는 불투명 JSON(있으면 arena 소유).
pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

// ── message 스키마(§1) ────────────────────────────────────────────────────────────────────────────────────
/// JSON-RPC id. 명세상 String·Number·Null만 허용된다(§4 "요청/응답은 id로 매칭"). Number는 i64로 좁힌다(id에
/// 소수부는 SHOULD NOT — 명세). 문자열/큰 정수(number_string)·실수·객체 id는 parse에서 InvalidRequest로 거부한다.
pub const Id = union(enum) {
    null,
    number: i64,
    string: []const u8,
};

/// 두 id의 값 동일성(request↔response 매칭용, §1). 문자열은 내용 비교(서로 다른 arena를 가리켜도 됨).
pub fn idEql(a: Id, b: Id) bool {
    return switch (a) {
        .null => b == .null,
        .number => |an| b == .number and b.number == an,
        .string => |as| b == .string and std.mem.eql(u8, as, b.string),
    };
}

/// 요청 `{jsonrpc, id, method, params?}`. `params`는 불투명 JSON(arena 소유, 없으면 null).
pub const Request = struct {
    id: Id,
    method: []const u8,
    params: ?std.json.Value = null,
};

/// notification `{jsonrpc, method, params?}` — id 없음(§1). 이벤트/hello가 이 모양.
pub const Notification = struct {
    method: []const u8,
    params: ?std.json.Value = null,
};

/// 응답 `{jsonrpc, id, result|error}`. `result`와 `err` 중 **정확히 하나**만 non-null이다(§5.1 불변식 — parse가 강제).
pub const Response = struct {
    id: Id,
    result: ?std.json.Value = null,
    err: ?RpcError = null,
};

/// 세 message 종류의 tagged union. classify(parse)가 어느 것인지 정한다.
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
};

// ── parse(바이트 → message) ───────────────────────────────────────────────────────────────────────────────
/// parse 실패. protocol 실패 둘(ParseError·InvalidRequest)은 JSON-RPC 에러 코드로 매핑되고(parseFailureCode),
/// OutOfMemory는 protocol 에러가 아니라 인프라 실패다.
pub const ParseFailure = error{
    /// 바이트 수준 잘못된 JSON → parse error(-32700).
    ParseError,
    /// 유효한 JSON이나 유효한 JSON-RPC message가 아님 → invalid request(-32600).
    InvalidRequest,
    OutOfMemory,
};

/// ParseFailure를 응답에 실을 ErrorCode로 매핑한다. OutOfMemory는 internal_error로 접는다(응답을 만들 수 있을 때).
pub fn parseFailureCode(e: ParseFailure) ErrorCode {
    return switch (e) {
        error.ParseError => .parse_error,
        error.InvalidRequest => .invalid_request,
        error.OutOfMemory => .internal_error,
    };
}

/// parse 결과. std.json arena를 소유하므로 **`deinit` 필수**. `message`의 슬라이스·Value는 arena 수명에 묶인다.
pub const ParsedMessage = struct {
    parsed: std.json.Parsed(std.json.Value),
    message: Message,

    pub fn deinit(self: ParsedMessage) void {
        self.parsed.deinit();
    }
};

/// 한 ndjson frame(개행 없는 한 줄)을 JSON-RPC message로 parse한다. 성공 시 arena 소유 `ParsedMessage`를 돌려주고
/// caller가 deinit한다. 실패는 ParseFailure(§위). frame 추출(개행 경계·부분읽기 누적)은 `Framer`가 담당한다.
pub fn parseMessage(gpa: std.mem.Allocator, bytes: []const u8) ParseFailure!ParsedMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError, // 그 밖의 모든 스캐너/구문 오류 = 바이트 수준 malformed.
    };
    errdefer parsed.deinit();
    const message = try classify(parsed.value);
    return .{ .parsed = parsed, .message = message };
}

/// 파싱된 JSON Value를 message 종류로 분류한다(순수, 할당 없음 — 슬라이스는 root arena를 빌린다).
/// 분류 규칙(§1): `method` 있음 + `id` 있음 = request, `method` 있음 + `id` 없음 = notification,
/// `method` 없음 + `id` 있음 + (result XOR error) = response. 그 외는 InvalidRequest.
fn classify(root: std.json.Value) error{InvalidRequest}!Message {
    const obj = switch (root) {
        .object => |o| o, // 단일 message = JSON 객체. 배치 배열은 1a 범위 밖(§1 "message 1개 = 1줄").
        else => return error.InvalidRequest,
    };

    // jsonrpc 필드는 정확히 "2.0"이어야 한다(§10).
    const jver = obj.get("jsonrpc") orelse return error.InvalidRequest;
    const jver_s = switch (jver) {
        .string => |s| s,
        else => return error.InvalidRequest,
    };
    if (!std.mem.eql(u8, jver_s, jsonrpc_version)) return error.InvalidRequest;

    const id_present = obj.get("id");
    if (obj.get("method")) |method_v| {
        const method = switch (method_v) {
            .string => |s| s,
            else => return error.InvalidRequest, // method는 문자열이어야.
        };
        const params = normalizeParams(obj.get("params"));
        if (id_present) |idv| {
            return .{ .request = .{ .id = try parseId(idv), .method = method, .params = params } };
        }
        return .{ .notification = .{ .method = method, .params = params } };
    }

    // method 없음 → response여야 한다.
    const idv = id_present orelse return error.InvalidRequest;
    const id = try parseId(idv);
    const result_v = obj.get("result");
    const error_v = obj.get("error");
    // result와 error는 정확히 하나만(§5.1).
    if ((result_v != null) == (error_v != null)) return error.InvalidRequest;

    if (result_v) |rv| {
        return .{ .response = .{ .id = id, .result = rv, .err = null } };
    }
    // error 객체 파싱.
    const eo = switch (error_v.?) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };
    const code = switch (eo.get("code") orelse return error.InvalidRequest) {
        .integer => |i| i,
        else => return error.InvalidRequest,
    };
    const emsg = switch (eo.get("message") orelse return error.InvalidRequest) {
        .string => |s| s,
        else => return error.InvalidRequest,
    };
    return .{ .response = .{
        .id = id,
        .result = null,
        .err = .{ .code = code, .message = emsg, .data = eo.get("data") },
    } };
}

fn parseId(v: std.json.Value) error{InvalidRequest}!Id {
    return switch (v) {
        .integer => |i| .{ .number = i },
        .string => |s| .{ .string = s },
        .null => .null,
        // float / bool / object / array / number_string(i64 밖 정수) id는 명세상 부적합 → 거부.
        else => error.InvalidRequest,
    };
}

/// 명시적 JSON null params는 "params 없음"과 동일하게 접는다(명세상 params가 있으면 object/array여야 하나, null을
/// 보내는 클라이언트가 있어 관대하게 처리 — dispatch가 실제 shape를 검증).
fn normalizeParams(p: ?std.json.Value) ?std.json.Value {
    const v = p orelse return null;
    return switch (v) {
        .null => null,
        else => v,
    };
}

// ── serialize(message → 바이트, 한 줄) ────────────────────────────────────────────────────────────────────
// 모든 serialize는 minified(공백/개행 0) → 한 줄 불변식을 지킨다. JSON 문자열 escape가 payload 안 개행(\n)을
// `\\n`으로 바꾸므로 raw 개행이 절대 새지 않는다(ndjson frame 경계 안전). 종단 `\n`은 프레이밍 계층(1b)이 붙인다.

/// message를 한 줄 JSON(개행 없음)으로 직렬화한다. caller가 소유 슬라이스를 free한다.
pub fn serializeMessage(gpa: std.mem.Allocator, msg: Message) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeMessage(&aw.writer, msg) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeMessage(w: *std.Io.Writer, msg: Message) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    switch (msg) {
        .request => |r| {
            try s.beginObject();
            try s.objectField("jsonrpc");
            try s.write(jsonrpc_version);
            try s.objectField("id");
            try writeId(&s, r.id);
            try s.objectField("method");
            try s.write(r.method);
            if (r.params) |p| {
                try s.objectField("params");
                try s.write(p);
            }
            try s.endObject();
        },
        .notification => |n| {
            try s.beginObject();
            try s.objectField("jsonrpc");
            try s.write(jsonrpc_version);
            try s.objectField("method");
            try s.write(n.method);
            if (n.params) |p| {
                try s.objectField("params");
                try s.write(p);
            }
            try s.endObject();
        },
        .response => |resp| {
            try s.beginObject();
            try s.objectField("jsonrpc");
            try s.write(jsonrpc_version);
            try s.objectField("id");
            try writeId(&s, resp.id);
            if (resp.err) |e| {
                try s.objectField("error");
                try s.beginObject();
                try s.objectField("code");
                try s.write(e.code);
                try s.objectField("message");
                try s.write(e.message);
                if (e.data) |d| {
                    try s.objectField("data");
                    try s.write(d);
                }
                try s.endObject();
            } else {
                // 성공 응답은 result를 반드시 실는다(null result도 유효한 성공 결과 — §5.1).
                try s.objectField("result");
                try s.write(resp.result orelse std.json.Value.null);
            }
            try s.endObject();
        },
    }
}

fn writeId(s: *std.json.Stringify, id: Id) !void {
    switch (id) {
        .null => try s.write(null),
        .number => |n| try s.write(n),
        .string => |str| try s.write(str),
    }
}

/// 에러 응답 `{jsonrpc, id, error:{code, message, data?}}`를 한 줄로 직렬화하는 편의(§5.1). id를 아직 못 읽은
/// 프레이밍/parse 실패는 `.null` id로 부른다(JSON-RPC 관례). caller가 free.
pub fn serializeError(
    gpa: std.mem.Allocator,
    id: Id,
    code: ErrorCode,
    message: []const u8,
    data: ?std.json.Value,
) std.mem.Allocator.Error![]u8 {
    return serializeMessage(gpa, .{ .response = .{
        .id = id,
        .err = .{ .code = @intFromEnum(code), .message = message, .data = data },
    } });
}

// ── hello notification(§4.1) ─────────────────────────────────────────────────────────────────────────────
/// 핸드셰이크 hello의 params `{protocol, server_version, capabilities}`(§4.1). `server_version`·`capabilities`는
/// L4(소켓 서버, 1b)가 실제 값을 주입한다 — 이 순수 코어는 스키마·직렬화만.
pub const HelloParams = struct {
    server_version: []const u8,
    capabilities: []const []const u8,
    protocol: []const u8 = protocol_id,
};

/// hello를 notification으로 직렬화한다: `{"jsonrpc":"2.0","method":"hello","params":{...}}`. caller가 free.
pub fn serializeHello(gpa: std.mem.Allocator, params: HelloParams) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeHello(&aw.writer, params) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeHello(w: *std.Io.Writer, params: HelloParams) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(jsonrpc_version);
    try s.objectField("method");
    try s.write(hello_method);
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("protocol");
    try s.write(params.protocol);
    try s.objectField("server_version");
    try s.write(params.server_version);
    try s.objectField("capabilities");
    try s.write(params.capabilities); // []const []const u8 → JSON 문자열 배열.
    try s.endObject();
    try s.endObject();
}

// ── ndjson 프레이머(§4.3) ─────────────────────────────────────────────────────────────────────────────────
/// ndjson 프레이머: 바이트 스트림(부분 읽기, 줄이 여러 read에 걸쳐 도착)을 개행 경계로 frame(한 줄)으로 조립한다.
///
/// 계약:
/// - `push(gpa, bytes)`로 read 결과를 넣는다(누적 버퍼에 append). 줄이 완결되지 않아도 다음 push까지 보존한다.
/// - `next()`로 완결된 frame을 하나씩 뺀다. 없으면 null(더 읽어야 함). frame 슬라이스는 **다음 push/next 호출까지**
///   유효하다(그 호출이 소비분을 버퍼에서 버린다).
/// - 빈 줄(개행만, `\r\n` 포함)은 message가 아니라 no-op으로 건너뛴다(ndjson 관례 — keepalive 개행 방어).
/// - max frame(§4.3) 초과 시 `next()`가 `error.PayloadTooLarge`를 돌려주고 `too_large`가 sticky로 선다. 소켓 계층
///   (1b)이 payload-too-large 응답 후 연결을 종료한다(여긴 소켓이 없어 상태만 알린다). 초과 판정 둘: (a) 완결 frame이
///   max 초과(next에서 검출), (b) 미완결 tail(마지막 개행 뒤)이 max 초과(push에서 검출 — 무한 누적 OOM 방어).
pub const Framer = struct {
    /// 누적 버퍼. `pending_consume` 바이트는 직전 next()가 돌려준 뒤 아직 안 버린 소비분이다(다음 mutating 호출에서 drop).
    buf: std.ArrayList(u8) = .empty,
    max_frame: usize = default_max_frame,
    too_large: bool = false,
    pending_consume: usize = 0,

    pub fn deinit(self: *Framer, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    /// 직전 next()가 돌려준 frame(+종단 개행)을 버퍼에서 버린다. 다음 push/next 시작에 호출된다.
    fn drainConsumed(self: *Framer) void {
        if (self.pending_consume == 0) return;
        const rest_len = self.buf.items.len - self.pending_consume;
        std.mem.copyForwards(u8, self.buf.items[0..rest_len], self.buf.items[self.pending_consume..]);
        self.buf.items.len = rest_len;
        self.pending_consume = 0;
    }

    /// read 결과 바이트를 누적한다. 마지막 개행 뒤 미완결 tail이 max_frame을 넘으면 too_large를 세운다.
    pub fn push(self: *Framer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!void {
        self.drainConsumed();
        try self.buf.appendSlice(gpa, bytes);
        const tail_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items, '\n')) |i| i + 1 else 0;
        if (self.buf.items.len - tail_start > self.max_frame) self.too_large = true;
    }

    /// 다음 완결 frame(개행 제외, 선행 `\r` strip)을 돌려준다. 없으면 null. max 초과면 error.PayloadTooLarge.
    pub fn next(self: *Framer) error{PayloadTooLarge}!?[]const u8 {
        self.drainConsumed();
        if (self.too_large) return error.PayloadTooLarge;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.buf.items, start, '\n')) |nl| {
            var line = self.buf.items[start..nl];
            if (line.len > self.max_frame) {
                self.too_large = true;
                return error.PayloadTooLarge;
            }
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) {
                start = nl + 1; // 빈 줄 skip.
                continue;
            }
            self.pending_consume = nl + 1; // 이 frame + 종단 개행을 다음 호출에 버린다.
            return line;
        }
        // 완결 frame 없음. 앞서 건너뛴 빈 줄들은 다음 호출에 버린다.
        if (start > 0) self.pending_consume = start;
        return null;
    }
};

// ── method 네임스페이스 파싱(§4.1) ───────────────────────────────────────────────────────────────────────
/// 예약된 코어 네임스페이스(§4.1). **분류만** 한다 — 값에 라우팅 의미를 넣지 않고, 여기에 없는 네임스페이스도
/// 거부하지 않는다(§4.1 "닫힌 하드코딩 테이블이 아니라 코어 표 + 등록 가능한 확장 핸들러"). 실제 dispatch는 후속 slice.
pub const CoreNamespace = enum { sessions, session, panel, browser };
/// 확장 네임스페이스 접두사(§4.1 `plugin.<id>.*`).
pub const plugin_namespace = "plugin";

/// 파싱된 method 이름. 네임스페이스는 verbatim으로 보존하고(닫힌 테이블 아님), 코어 예약어면 `core`를 채운다.
pub const ParsedMethod = struct {
    /// 첫 dot 이전 세그먼트 verbatim(예: "sessions", "plugin", "custom"). dot이 없으면 method 전체.
    namespace: []const u8,
    /// namespace가 코어 예약어면 그 enum, 아니면 null(확장/미지). null이라고 무효가 아니다 — dispatch가 등록 핸들러로 라우팅.
    core: ?CoreNamespace,
    /// `plugin.<id>.*`의 `<id>`(둘째 세그먼트). plugin이 아니거나 id가 없으면 null.
    plugin_id: ?[]const u8,
    /// 네임스페이스(+plugin id) 이후의 나머지 method. 예: sessions.list→"list", plugin.x.y.z→"y.z". dot 없으면 "".
    rest: []const u8,
    /// 원본 method 문자열.
    raw: []const u8,
};

/// method 문자열을 네임스페이스/나머지로 쪼갠다(순수, 할당 없음 — 슬라이스는 raw를 빌린다). 하드코딩 dispatch가
/// 아니라 파싱만 — 코어 예약어 인식과 plugin id 추출까지.
pub fn parseMethod(raw: []const u8) ParsedMethod {
    const first_dot = std.mem.indexOfScalar(u8, raw, '.');
    const ns = if (first_dot) |i| raw[0..i] else raw;
    const after_ns = if (first_dot) |i| raw[i + 1 ..] else "";
    var plugin_id: ?[]const u8 = null;
    var rest = after_ns;
    if (std.mem.eql(u8, ns, plugin_namespace)) {
        if (std.mem.indexOfScalar(u8, after_ns, '.')) |j| {
            plugin_id = after_ns[0..j];
            rest = after_ns[j + 1 ..];
        } else {
            plugin_id = if (after_ns.len > 0) after_ns else null;
            rest = "";
        }
    }
    return .{
        .namespace = ns,
        .core = coreNamespaceFromName(ns),
        .plugin_id = plugin_id,
        .rest = rest,
        .raw = raw,
    };
}

fn coreNamespaceFromName(name: []const u8) ?CoreNamespace {
    inline for (@typeInfo(CoreNamespace).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @field(CoreNamespace, f.name);
    }
    return null;
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직이라 OS·소켓 무관) ═══════════════════════════════════════════
const testing = std.testing;

// ── 1) request/response/notification parse·serialize 왕복 ──
test "round-trip: request(id+method+params)가 parse→serialize→parse에서 보존된다" {
    const raw =
        \\{"jsonrpc":"2.0","id":7,"method":"session.sendText","params":{"id":5,"text":"hi"}}
    ;
    var pm = try parseMessage(testing.allocator, raw);
    defer pm.deinit();
    try testing.expect(pm.message == .request);
    const req = pm.message.request;
    try testing.expect(idEql(req.id, .{ .number = 7 }));
    try testing.expectEqualStrings("session.sendText", req.method);
    try testing.expect(req.params != null);

    // 다시 직렬화 → 재파싱해서 payload까지 보존됐는지 확인(불투명 Value 왕복).
    const wire = try serializeMessage(testing.allocator, pm.message);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null); // 한 줄 불변식.
    var pm2 = try parseMessage(testing.allocator, wire);
    defer pm2.deinit();
    const req2 = pm2.message.request;
    try testing.expectEqualStrings("session.sendText", req2.method);
    try testing.expect(idEql(req2.id, .{ .number = 7 }));
    const text = req2.params.?.object.get("text").?.string;
    try testing.expectEqualStrings("hi", text);
}

test "round-trip: notification(id 없음)은 request와 구별된다" {
    const raw =
        \\{"jsonrpc":"2.0","method":"session.stateChanged","params":{"state":"idle"}}
    ;
    var pm = try parseMessage(testing.allocator, raw);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    try testing.expectEqualStrings("session.stateChanged", pm.message.notification.method);

    // 직렬화된 notification에는 "id" 키가 없어야 한다.
    const wire = try serializeMessage(testing.allocator, pm.message);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "\"id\"") == null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"method\":\"session.stateChanged\"") != null);
}

test "round-trip: 성공 response·에러 response 왕복(result XOR error)" {
    // 성공 응답.
    {
        const raw =
            \\{"jsonrpc":"2.0","id":3,"result":{"ok":true}}
        ;
        var pm = try parseMessage(testing.allocator, raw);
        defer pm.deinit();
        try testing.expect(pm.message == .response);
        try testing.expect(pm.message.response.result != null);
        try testing.expect(pm.message.response.err == null);
        const wire = try serializeMessage(testing.allocator, pm.message);
        defer testing.allocator.free(wire);
        try testing.expect(std.mem.indexOf(u8, wire, "\"result\"") != null);
        try testing.expect(std.mem.indexOf(u8, wire, "\"error\"") == null);
    }
    // 에러 응답.
    {
        const raw =
            \\{"jsonrpc":"2.0","id":"abc","error":{"code":-32601,"message":"Method not found"}}
        ;
        var pm = try parseMessage(testing.allocator, raw);
        defer pm.deinit();
        try testing.expect(pm.message == .response);
        try testing.expect(pm.message.response.err != null);
        try testing.expectEqual(@as(i64, -32601), pm.message.response.err.?.code);
        try testing.expect(idEql(pm.message.response.id, .{ .string = "abc" }));
    }
}

// ── 2) id 매칭 ──
test "id 매칭: response.id가 request.id와 값으로 일치(number·string), null id 왕복" {
    // number id.
    {
        var req = try parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"sessions.list\"}");
        defer req.deinit();
        // 같은 id로 응답을 만든다.
        const wire = try serializeMessage(testing.allocator, .{ .response = .{
            .id = req.message.request.id,
            .result = std.json.Value{ .bool = true },
        } });
        defer testing.allocator.free(wire);
        var resp = try parseMessage(testing.allocator, wire);
        defer resp.deinit();
        try testing.expect(idEql(resp.message.response.id, req.message.request.id));
    }
    // string id.
    {
        var req = try parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"sessions.list\"}");
        defer req.deinit();
        try testing.expect(idEql(req.message.request.id, .{ .string = "req-1" }));
        try testing.expect(!idEql(req.message.request.id, .{ .string = "req-2" }));
    }
    // null id 왕복(프레이밍/parse 실패 응답 경로).
    {
        const wire = try serializeError(testing.allocator, .null, .parse_error, "Parse error", null);
        defer testing.allocator.free(wire);
        var resp = try parseMessage(testing.allocator, wire);
        defer resp.deinit();
        try testing.expect(resp.message.response.id == .null);
    }
}

// ── 3) 에러 모델 ──
test "에러 코드: 표준 5개 + payload-too-large 코드값과 default message" {
    try testing.expectEqual(@as(i64, -32700), @intFromEnum(ErrorCode.parse_error));
    try testing.expectEqual(@as(i64, -32600), @intFromEnum(ErrorCode.invalid_request));
    try testing.expectEqual(@as(i64, -32601), @intFromEnum(ErrorCode.method_not_found));
    try testing.expectEqual(@as(i64, -32602), @intFromEnum(ErrorCode.invalid_params));
    try testing.expectEqual(@as(i64, -32603), @intFromEnum(ErrorCode.internal_error));
    // payload-too-large는 impl-defined server-error 범위(-32000~-32099)에 있어야 한다.
    const ptl = @intFromEnum(ErrorCode.payload_too_large);
    try testing.expect(ptl >= -32099 and ptl <= -32000);
    try testing.expectEqualStrings("Method not found", ErrorCode.method_not_found.defaultMessage());
}

test "에러 모델: 각 표준 코드가 에러 응답으로 직렬화된다" {
    for ([_]ErrorCode{ .parse_error, .invalid_request, .method_not_found, .invalid_params, .internal_error, .payload_too_large }) |code| {
        const wire = try serializeError(testing.allocator, .{ .number = 1 }, code, code.defaultMessage(), null);
        defer testing.allocator.free(wire);
        var pm = try parseMessage(testing.allocator, wire);
        defer pm.deinit();
        try testing.expectEqual(@as(i64, @intFromEnum(code)), pm.message.response.err.?.code);
        try testing.expectEqualStrings(code.defaultMessage(), pm.message.response.err.?.message);
    }
}

test "에러 모델: malformed JSON → ParseError(-32700)" {
    try testing.expectError(error.ParseError, parseMessage(testing.allocator, "{not json"));
    try testing.expectError(error.ParseError, parseMessage(testing.allocator, ""));
    try testing.expectError(error.ParseError, parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\","));
    try testing.expectEqual(ErrorCode.parse_error, parseFailureCode(error.ParseError));
}

test "에러 모델: 유효 JSON이나 유효 message 아님 → InvalidRequest(-32600)" {
    // jsonrpc 필드 부재.
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "{\"id\":1,\"method\":\"x\"}"));
    // jsonrpc 버전 불일치.
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}"));
    // method도 없고 response(result/error)도 아님.
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1}"));
    // method가 문자열이 아님.
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":5}"));
    // response인데 result와 error가 둘 다 있음(정확히 하나 위반).
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{\"code\":-1,\"message\":\"m\"}}"));
    // JSON 배열(단일 객체 아님) — 배치는 1a 범위 밖.
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "[]"));
    // id가 실수(부적합 id 타입).
    try testing.expectError(error.InvalidRequest, parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"x\"}"));
    try testing.expectEqual(ErrorCode.invalid_request, parseFailureCode(error.InvalidRequest));
}

// ── 4) ndjson 프레이밍 ──
test "프레이밍: 한 줄 message 추출" {
    var f: Framer = .{};
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"a\"}\n");
    const line = (try f.next()).?;
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"a\"}", line);
    try testing.expect((try f.next()) == null); // 더 없음.
}

test "프레이밍: 한 push에 여러 줄 → 순서대로 추출" {
    var f: Framer = .{};
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "one\ntwo\nthree\n");
    try testing.expectEqualStrings("one", (try f.next()).?);
    try testing.expectEqualStrings("two", (try f.next()).?);
    try testing.expectEqualStrings("three", (try f.next()).?);
    try testing.expect((try f.next()) == null);
}

test "프레이밍: 줄이 read 경계에 걸쳐 부분 도착해도 누적 조립된다" {
    var f: Framer = .{};
    defer f.deinit(testing.allocator);
    // 첫 read: 줄 절반, 개행 없음 → 아직 frame 없음.
    try f.push(testing.allocator, "{\"jsonrpc\":\"2.");
    try testing.expect((try f.next()) == null);
    // 둘째 read: 나머지 + 개행 → 완결.
    try f.push(testing.allocator, "0\",\"method\":\"a\"}\n");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"a\"}", (try f.next()).?);
    try testing.expect((try f.next()) == null);

    // 개행이 다음 read 선두에 오는 경우도 조립.
    try f.push(testing.allocator, "payload-without-nl");
    try testing.expect((try f.next()) == null);
    try f.push(testing.allocator, "\nnext\n");
    try testing.expectEqualStrings("payload-without-nl", (try f.next()).?);
    try testing.expectEqualStrings("next", (try f.next()).?);
}

test "프레이밍: 빈 줄(및 \\r\\n CRLF)은 건너뛴다" {
    var f: Framer = .{};
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "\n\r\nreal\r\n\nreal2\n");
    try testing.expectEqualStrings("real", (try f.next()).?); // CR strip
    try testing.expectEqualStrings("real2", (try f.next()).?);
    try testing.expect((try f.next()) == null);
}

test "프레이밍: 완결 frame이 max_frame 초과 → PayloadTooLarge(sticky)" {
    var f: Framer = .{ .max_frame = 8 };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "123456789\n"); // 9 바이트 줄 > 8.
    try testing.expectError(error.PayloadTooLarge, f.next());
    try testing.expect(f.too_large);
    try testing.expectError(error.PayloadTooLarge, f.next()); // sticky.
}

test "프레이밍: 미완결 tail이 max_frame 초과하면 개행 오기 전에 too_large(무한 누적 방어)" {
    var f: Framer = .{ .max_frame = 8 };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "12345"); // 5 ≤ 8, 아직 정상.
    try testing.expect(!f.too_large);
    try f.push(testing.allocator, "6789"); // 누적 9 > 8, 개행 없이도 too_large.
    try testing.expect(f.too_large);
    try testing.expectError(error.PayloadTooLarge, f.next());
}

test "프레이밍: 정확히 max_frame 길이 줄은 허용(초과만 거부)" {
    var f: Framer = .{ .max_frame = 4 };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "abcd\n"); // 줄 길이 4 == max, 허용.
    try testing.expectEqualStrings("abcd", (try f.next()).?);
    try testing.expect(!f.too_large);
}

test "프레이밍→parse 통합: 프레이머가 뽑은 줄이 곧바로 parse된다" {
    var f: Framer = .{};
    defer f.deinit(testing.allocator);
    const a = try serializeMessage(testing.allocator, .{ .notification = .{ .method = "a" } });
    defer testing.allocator.free(a);
    const b = try serializeMessage(testing.allocator, .{ .notification = .{ .method = "b" } });
    defer testing.allocator.free(b);
    // 소켓처럼 join하고 개행 붙여 흘려보낸다.
    try f.push(testing.allocator, a);
    try f.push(testing.allocator, "\n");
    try f.push(testing.allocator, b);
    try f.push(testing.allocator, "\n");
    var got: [2][]const u8 = undefined;
    var n: usize = 0;
    while (try f.next()) |line| {
        var pm = try parseMessage(testing.allocator, line);
        defer pm.deinit();
        got[n] = try testing.allocator.dupe(u8, pm.message.notification.method);
        n += 1;
    }
    defer for (got[0..n]) |g| testing.allocator.free(g);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", got[0]);
    try testing.expectEqualStrings("b", got[1]);
}

test "프레이밍: payload 안 개행은 escape되어 frame을 쪼개지 않는다" {
    // text에 실제 개행을 넣어 직렬화하면 JSON escape(\\n)라 wire엔 raw 개행이 없다.
    const raw =
        \\{"jsonrpc":"2.0","method":"m","params":{"text":"line1\nline2"}}
    ;
    var pm = try parseMessage(testing.allocator, raw);
    defer pm.deinit();
    const wire = try serializeMessage(testing.allocator, pm.message);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null); // raw 개행 없음.

    var f: Framer = .{};
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, wire);
    try f.push(testing.allocator, "\n");
    const line = (try f.next()).?;
    var pm2 = try parseMessage(testing.allocator, line);
    defer pm2.deinit();
    // 개행이 보존된 채 한 frame으로 파싱된다.
    try testing.expectEqualStrings("line1\nline2", pm2.message.notification.params.?.object.get("text").?.string);
}

// ── 5) hello notification ──
test "hello: protocol/server_version/capabilities를 담은 notification으로 직렬화" {
    const caps = [_][]const u8{ "sessions.list", "session.get", "session.capture" };
    const wire = try serializeHello(testing.allocator, .{
        .server_version = "0.1.0",
        .capabilities = &caps,
    });
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null);

    var pm = try parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .notification); // id 없음 = notification.
    const n = pm.message.notification;
    try testing.expectEqualStrings(hello_method, n.method);
    const p = n.params.?.object;
    try testing.expectEqualStrings(protocol_id, p.get("protocol").?.string);
    try testing.expectEqualStrings("maru.control.v1", p.get("protocol").?.string);
    try testing.expectEqualStrings("0.1.0", p.get("server_version").?.string);
    const arr = p.get("capabilities").?.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqualStrings("sessions.list", arr.items[0].string);
    try testing.expectEqualStrings("session.capture", arr.items[2].string);
}

// ── 6) method 네임스페이스 파싱 ──
test "네임스페이스: 코어 sessions/session/panel/browser 인식 + rest 분리" {
    {
        const m = parseMethod("sessions.list");
        try testing.expectEqualStrings("sessions", m.namespace);
        try testing.expectEqual(CoreNamespace.sessions, m.core.?);
        try testing.expectEqualStrings("list", m.rest);
        try testing.expect(m.plugin_id == null);
    }
    {
        const m = parseMethod("session.sendKeys");
        try testing.expectEqual(CoreNamespace.session, m.core.?);
        try testing.expectEqualStrings("sendKeys", m.rest);
    }
    {
        const m = parseMethod("panel.open");
        try testing.expectEqual(CoreNamespace.panel, m.core.?);
    }
    {
        const m = parseMethod("browser.navigate");
        try testing.expectEqual(CoreNamespace.browser, m.core.?);
        try testing.expectEqualStrings("navigate", m.rest);
    }
}

test "네임스페이스: plugin.<id>.* 는 plugin_id와 나머지 method를 분리" {
    {
        const m = parseMethod("plugin.x.y");
        try testing.expectEqualStrings("plugin", m.namespace);
        try testing.expect(m.core == null); // plugin은 코어 예약어가 아니다.
        try testing.expectEqualStrings("x", m.plugin_id.?);
        try testing.expectEqualStrings("y", m.rest);
    }
    {
        // 다중 세그먼트 method: plugin.foo.bar.baz → id=foo, rest="bar.baz".
        const m = parseMethod("plugin.foo.bar.baz");
        try testing.expectEqualStrings("foo", m.plugin_id.?);
        try testing.expectEqualStrings("bar.baz", m.rest);
    }
    {
        // id만 있고 method 없음.
        const m = parseMethod("plugin.only");
        try testing.expectEqualStrings("only", m.plugin_id.?);
        try testing.expectEqualStrings("", m.rest);
    }
}

test "네임스페이스: 미지 네임스페이스도 거부하지 않고 verbatim 보존(닫힌 테이블 아님)" {
    const m = parseMethod("custom.thing");
    try testing.expectEqualStrings("custom", m.namespace);
    try testing.expect(m.core == null); // 코어 아님이지만 무효도 아님.
    try testing.expect(m.plugin_id == null);
    try testing.expectEqualStrings("thing", m.rest);

    // dot 없는 bare method.
    const bare = parseMethod("ping");
    try testing.expectEqualStrings("ping", bare.namespace);
    try testing.expect(bare.core == null);
    try testing.expectEqualStrings("", bare.rest);
}
