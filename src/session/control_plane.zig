//! control_plane — 세션 컨트롤 플레인 wire 프로토콜의 L2 순수 코어 (schema/parser/framing/error-model).
//! Track C slice 1a. 단일 출처: docs/control-plane.md §1·§10, docs/control-plane-protocol.md §4.1·§4.3,
//! docs/control-plane-implementation.md §16.
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
//! 슬라이스·Value는 arena 수명에 묶인다.
//!
//! **alloc 전략 결정(범위 애매점 보고 대상):** std.json.parseFromSlice가 arena 소유를 강요하므로, parse는
//! `gpa`를 받아 arena를 소유한 `ParsedMessage`를 돌려주고 caller가 `deinit`한다(leaky 변형은 두지 않는다 — 컨트롤
//! 플레인은 frame당 parse→dispatch→free 수명이라 소유 wrapper가 자연스럽다). serialize도 `gpa`를 받아 소유
//! 슬라이스를 돌려준다(streaming std.json.Stringify → Allocating writer). 둘 다 최소 선택이며 소켓 buffer 전략은 1b.

const std = @import("std");

// ── 상수 ──────────────────────────────────────────────────────────────────────────────────────────────────
/// JSON-RPC 2.0 version 태그. 모든 message의 `jsonrpc` 필드는 정확히 이 값이어야 한다(§10).
pub const jsonrpc_version = "2.0";
/// 핸드셰이크가 광고하는 프로토콜 식별자(docs/control-plane-protocol.md §4.1). 버전 skew 감지에 쓴다.
pub const protocol_id = "maru.control.v1";
/// `hello` notification의 method 이름(§4.1).
pub const hello_method = "hello";
/// `browser.screenshotChunk` notification의 method 이름(§9.5.7 — screenshot chunk-streaming). 생산(control_browser
/// `serializeScreenshotChunk`)과 소비(cli/browser `ScreenshotStreamValidator`)가 이 **단일 출처**를 공유해 wire drift를 막는다.
pub const browser_screenshot_chunk_method = "browser.screenshotChunk";
pub const browser_execute_script_chunk_method = "browser.executeScriptChunk";
pub const browser_snapshot_chunk_method = "browser.snapshotChunk"; // §9.5.10 통일-1: snapshot 대형 결과 chunk 스트림(executeScript와 같은 transfer)
pub const browser_console_chunk_method = "browser.consoleChunk"; // §9.5.10 통일-2: console 대형 결과 chunk 스트림(snapshot과 같은 transfer)

/// PNG IHDR width/height(§9.5.7 screenshot metadata). **단일 출처**: 서버(control_browser)와 CLI 클라이언트가 같은
/// 파서를 써야 유효 PNG 판정이 어긋나지 않는다(cli는 cp만 import하므로 여기 둔다). 시그니처 8B + IHDR(len 4·"IHDR" 4·
/// width 4 BE[16]·height 4 BE[20])만 읽는다. 24B 미만·시그니처 불일치·0 크기 → null.
pub const PngDims = struct { width: u32, height: u32 };
pub fn pngDimensions(bytes: []const u8) ?PngDims {
    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], &png_sig)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null; // bytes[8..12]=IHDR length(=13)
    const width = std.mem.readInt(u32, bytes[16..][0..4], .big);
    const height = std.mem.readInt(u32, bytes[20..][0..4], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}
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
    /// authz 실패(§8.3). surface-scoped 메서드가 granted scope로 대상 surface를 볼 수 없을 때, **존재 여부와
    /// 무관하게 존재검사 이전에** 이 균일 오류를 돌려준다(surface_id 열거 oracle 방지 — §8.3). 코드값 -32002는
    /// impl-defined server-error 범위(-32000~-32099)에서 maru가 택한 값(명세 미지정 — document-basis-and-decision).
    unauthorized = -32002,
    /// 대상 surface가 (인가는 됐으나) 더는 존재하지 않음(§5·§8.3 "없음/process-exited"). 인가 통과 후 snapshot에
    /// 그 surface가 없을 때만 반환하므로 oracle이 아니다(호출자는 이미 그 surface를 볼 권한이 있다). 코드값 -32003도
    /// impl-defined server-error 범위에서 maru가 택한 값.
    process_exited = -32003,
    /// 조건 기반 browser wait가 요청한 제한 시간 안에 충족되지 않음(§9.4/§9.5). 일반 transport timeout과 달리
    /// 서버가 정상 응답한 **도메인 실패**라 연결을 유지할 수 있다. data에 condition/timeout_ms를 싣는다.
    timeout = -32004,
    result_too_large = -32005,
    script_error = -32006,
    resource_busy = -32007,

    /// 이 코드의 표준 짧은 message(JSON-RPC §5.1의 관례). 에러 응답 build 편의.
    pub fn defaultMessage(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
            .payload_too_large => "Payload too large",
            .unauthorized => "Unauthorized",
            .process_exited => "Process exited",
            .timeout => "Timeout",
            .result_too_large => "Result too large",
            .script_error => "Script error",
            .resource_busy => "Resource busy",
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

/// JSON-RPC id(`Id` union)를 Stringify에 쓴다(null/number/string). 응답을 인라인으로 조립하는 후속 slice
/// (1c 디스패치 코어가 result에 surface JSON을 직접 실을 때 등)가 같은 id 표현을 재사용하도록 pub이다.
pub fn writeId(s: *std.json.Stringify, id: Id) !void {
    switch (id) {
        .null => try s.write(null),
        .number => |n| try s.write(n),
        .string => |str| try s.write(str),
    }
}

/// 성공 응답 result envelope `{"jsonrpc":"2.0","id":<id>,"result":{` 까지 연다(§5.1). body는 호출자가 채우고
/// `endResult`로 닫는다. `browser.*`(control_browser)·브리지(control_bridge) result 직렬화의 **단일 출처** — 응답
/// envelope 모양이 소켓·브리지 경로에서 드리프트하지 않게 한다(각 모듈 로컬 복제 대신 cp 재사용).
pub fn beginResult(s: *std.json.Stringify, id: Id) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(jsonrpc_version);
    try s.objectField("id");
    try writeId(s, id);
    try s.objectField("result");
    try s.beginObject();
}

/// `beginResult`가 연 result body와 envelope를 닫는다.
pub fn endResult(s: *std.json.Stringify) !void {
    try s.endObject(); // result body
    try s.endObject(); // envelope
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

/// id 미상(요청 id를 아직 못 읽음) + 코드 default message로 에러 응답 한 줄을 직렬화한다(개행 없음 — 프레이밍은 호출처).
/// **payload_too_large 등 "id 파싱 전 거부" 응답의 단일 출처**(19차 [5]): L4의 `control_socket.writeErrorResponse`(직접
/// 소켓 write)와 `control_server.readFrame`(outbound 큐 push)가 둘 다 이걸 써 바이트 형태가 갈리지 않게 한다. `.null` id는
/// JSON-RPC 관례(§4.3).
pub fn serializeErrorDefault(gpa: std.mem.Allocator, code: ErrorCode) std.mem.Allocator.Error![]u8 {
    return serializeError(gpa, .null, code, code.defaultMessage(), null);
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

// ── auth 셀렉터(§4.2·§8.4, A2b 최소 auth) ────────────────────────────────────────────────────────────────
/// caller가 연결 직후 보내는 self-origin 셀렉터 프레임의 method 이름(§8.4 1단계). request 프레임 앞에 온다.
pub const auth_self_method = "auth.self";

/// auth 프레임이 실을 수 있는 capability nonce의 바이트 길이(§8.5, 1e). **wire 수준 상수** — 1a(control_plane)는
/// capability(1e)를 import하지 않으므로(레이어 base) nonce를 "capability 개념"이 아니라 hex 인코딩된 고정폭 바이트로
/// 다룬다. `control_capability.nonce_len`과 **같은 값이어야 한다**(control_server가 comptime assert로 drift를 잡는다).
pub const auth_cap_nonce_len = 32;

/// auth 프레임 파싱 결과(§8.4·§8.5). `selector`=caller가 주장한 self surface_id(anchor), `cap_nonce`=선택적
/// capability nonce(1e — hex-decoded 고정폭). 둘 다 없을 수 있다(maru 밖 shell·no-cap CLI = selector만·anchor 없음).
pub const AuthFrame = struct {
    /// auth.self anchor(주장 self surface_id). 없으면 null(서버가 self를 안 줌).
    selector: ?u64 = null,
    /// 선택적 capability nonce(§8.5, 1e). 있으면 서버가 CapabilityStore로 resolve해 scope를 발급한다(없으면 self만).
    cap_nonce: ?[auth_cap_nonce_len]u8 = null,
};

/// A2b 최소 auth 셀렉터를 notification으로 직렬화한다: `{"jsonrpc":"2.0","method":"auth.self","params":{"surface_id":N,
/// "cap_nonce":"<hex>"}}`. `surface_id`는 caller가 자기 surface를 주장하는 값(CLI가 `$MARU_PANE_ID`에서 읽음 — 실제
/// env는 MARU_PANE_ID이고 그 값이 곧 surface_id다). `cap_nonce`(1e)는 CLI가 상속 capability fd(§8.5, MARU_CONTROL_CAP_FD)
/// 에서 읽은 nonce(hex, 실 fd 상속은 1e-core 범위 밖)를 실어 self보다 넓은 scope를 요청한다. 둘 다 null이면 params `{}`
/// (maru 밖 shell·no-cap = 서버가 metadata:self만, cap 없음). **§8.4 경계 정직**: selector는 비밀 토큰이 아니라 단순
/// 주장이다(tty/pgrp 검증은 1g 후속); cap_nonce는 §8.5 capability로 resolve되는 실 grant다.
pub fn serializeAuthSelf(gpa: std.mem.Allocator, surface_id: ?u64, cap_nonce: ?[auth_cap_nonce_len]u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeAuthSelf(&aw.writer, surface_id, cap_nonce) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeAuthSelf(w: *std.Io.Writer, surface_id: ?u64, cap_nonce: ?[auth_cap_nonce_len]u8) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(jsonrpc_version);
    try s.objectField("method");
    try s.write(auth_self_method);
    try s.objectField("params");
    try s.beginObject();
    if (surface_id) |sid| {
        try s.objectField("surface_id");
        try s.write(sid);
    }
    if (cap_nonce) |nonce| {
        try s.objectField("cap_nonce");
        const hex = std.fmt.bytesToHex(nonce, .lower); // [2*len]u8
        try s.write(&hex);
    }
    try s.endObject();
    try s.endObject();
}

/// auth 셀렉터 프레임 한 줄에서 `{selector, cap_nonce}`를 뽑는다(순수, 관대 파싱 — 서버 accept 스레드가 부른다).
///  - `selector`: notification `auth.self` + `params.surface_id`가 음이 아닌 정수 → 그 값, 아니면 null.
///  - `cap_nonce`: `params.cap_nonce`가 정확히 `2*auth_cap_nonce_len` hex 문자면 디코드한 바이트, 아니면 null
///    (부재·잘못된 길이·비-hex는 조용히 null = cap 없음).
/// 에러를 던지지 않는다(OOM·파싱 실패·다른 method는 전부 빈 AuthFrame으로 접는다) — 소켓 입력이라 방어적으로 다룬다.
pub fn parseAuthFrame(gpa: std.mem.Allocator, bytes: []const u8) AuthFrame {
    var pm = parseMessage(gpa, bytes) catch return .{};
    defer pm.deinit();
    if (pm.message != .notification) return .{};
    const notif = pm.message.notification;
    if (!std.mem.eql(u8, notif.method, auth_self_method)) return .{};
    const params = switch (notif.params orelse return .{}) {
        .object => |o| o,
        else => return .{},
    };
    var frame: AuthFrame = .{};
    if (params.get("surface_id")) |sid_v| {
        if (sid_v == .integer and sid_v.integer >= 0) frame.selector = @intCast(sid_v.integer);
    }
    if (params.get("cap_nonce")) |nonce_v| {
        if (nonce_v == .string and nonce_v.string.len == 2 * auth_cap_nonce_len) {
            var out: [auth_cap_nonce_len]u8 = undefined;
            if (std.fmt.hexToBytes(&out, nonce_v.string)) |decoded| {
                if (decoded.len == auth_cap_nonce_len) frame.cap_nonce = out;
            } else |_| {} // 비-hex → cap 없음(관대)
        }
    }
    return frame;
}

// ── auth.grant(§9.5.6 ③ cap 누적) ─────────────────────────────────────────────────────────────────────────
pub const auth_grant_method = "auth.grant";

/// `auth.grant` 프레임 직렬화: `{"jsonrpc":"2.0","method":"auth.grant","params":{"cap_nonce":"<hex>"}}`(응답 없는
/// notification). 지속 세션이 `auth.self` 뒤 이걸 반복해 **cap을 세션 집합에 누적**한다 — navigate(browser)+getCookies
/// (browser_storage)처럼 다중 scope를 single-scope cap 여럿으로 쓰기 위함(§9.5.6 ③). client(에이전트/CLI)가 상속한 각
/// capability fd의 nonce마다 한 번 보낸다.
pub fn serializeAuthGrant(gpa: std.mem.Allocator, cap_nonce: [auth_cap_nonce_len]u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    (writeAuthGrant(&aw.writer, cap_nonce)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}
fn writeAuthGrant(w: *std.Io.Writer, cap_nonce: [auth_cap_nonce_len]u8) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(jsonrpc_version);
    try s.objectField("method");
    try s.write(auth_grant_method);
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("cap_nonce");
    const hex = std.fmt.bytesToHex(cap_nonce, .lower);
    try s.write(&hex);
    try s.endObject();
    try s.endObject();
}

/// `auth.grant` 프레임에서 cap_nonce를 뽑는다(§9.5.6 ③). method가 `auth.grant`이고 `params.cap_nonce`가 유효 hex
/// (`2*auth_cap_nonce_len`)면 그 바이트, 아니면 **null**(비-auth.grant·부재·잘못된 길이·비-hex 전부 null=무시). serveConnection이
/// 요청 루프서 **매 프레임**을 이걸로 먼저 시험해, 매치되면 세션 cap 집합에 추가하고 요청으로 marshal하지 않는다(§8.3 관대 파싱).
///
/// **값싼 prefilter(22차 [5])**: `auth.grant` 리터럴이 바이트에 **없으면** 즉시 null — 매 프레임 루프서 도는데 정상 요청
/// (sessions.list·browser.navigate 등)은 이 리터럴이 없어 풀 `parseMessage`(Value 트리 alloc)를 건너뛴다(그 프레임은
/// dispatchAuthenticated가 어차피 다시 파싱하므로 여기 풀 파싱은 순수 낭비였음). 리터럴이 params 등에 우연히 있으면
/// 폴스루해 풀 파싱이 정확히 null 판정(안전 — auth.grant notification은 반드시 이 리터럴을 method로 포함).
pub fn parseAuthGrant(gpa: std.mem.Allocator, bytes: []const u8) ?[auth_cap_nonce_len]u8 {
    if (std.mem.indexOf(u8, bytes, auth_grant_method) == null) return null; // 값싼 fast-path(정상 프레임=풀 파싱 회피)
    var pm = parseMessage(gpa, bytes) catch return null;
    defer pm.deinit();
    if (pm.message != .notification) return null;
    if (!std.mem.eql(u8, pm.message.notification.method, auth_grant_method)) return null;
    const params = switch (pm.message.notification.params orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const nonce_v = params.get("cap_nonce") orelse return null;
    if (nonce_v != .string or nonce_v.string.len != 2 * auth_cap_nonce_len) return null;
    var out: [auth_cap_nonce_len]u8 = undefined;
    if (std.fmt.hexToBytes(&out, nonce_v.string)) |decoded| {
        if (decoded.len == auth_cap_nonce_len) return out;
    } else |_| {}
    return null;
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

    /// read 결과 바이트를 순수 누적만 한다. oversize 판정은 next()가 완결 frame을 다 뽑은 **뒤에** 한다
    /// (push에서 미완결 tail로 too_large를 세우면, 그 tail 앞에 이미 버퍼된 완결 유효 frame을 next()가 유실한다).
    pub fn push(self: *Framer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!void {
        self.drainConsumed();
        try self.buf.appendSlice(gpa, bytes);
    }

    /// 다음 완결 frame(개행 제외, 선행 `\r` strip)을 돌려준다. 없으면 null. max 초과면 error.PayloadTooLarge.
    /// **완결 frame을 먼저 전부 돌려준 뒤에** 미완결 tail의 oversize를 판정한다 — 유효 완결 frame 뒤에 oversize
    /// 미완결 tail이 붙어 있어도(한 read에 둘이 같이 도착) 앞의 유효 frame을 삼키지 않는다. too_large는 sticky.
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
        // 남은 미완결 tail(개행 없는 마지막 조각)이 max_frame을 넘으면 유효 frame이 될 수 없다 → OOM 방어로 거부.
        // 완결 frame을 다 돌려준 **뒤**라 앞선 유효 frame을 삼키지 않는다.
        if (self.buf.items.len - start > self.max_frame) {
            self.too_large = true;
            return error.PayloadTooLarge;
        }
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
test "에러 코드: 표준 5개 + maru 확장 코드값과 default message" {
    try testing.expectEqual(@as(i64, -32700), @intFromEnum(ErrorCode.parse_error));
    try testing.expectEqual(@as(i64, -32600), @intFromEnum(ErrorCode.invalid_request));
    try testing.expectEqual(@as(i64, -32601), @intFromEnum(ErrorCode.method_not_found));
    try testing.expectEqual(@as(i64, -32602), @intFromEnum(ErrorCode.invalid_params));
    try testing.expectEqual(@as(i64, -32603), @intFromEnum(ErrorCode.internal_error));
    // maru 확장 코드는 전부 impl-defined server-error 범위(-32000~-32099)에 있어야 한다.
    for ([_]ErrorCode{ .payload_too_large, .unauthorized, .process_exited, .timeout }) |ext| {
        const v = @intFromEnum(ext);
        try testing.expect(v >= -32099 and v <= -32000);
    }
    try testing.expectEqual(@as(i64, -32002), @intFromEnum(ErrorCode.unauthorized));
    try testing.expectEqual(@as(i64, -32003), @intFromEnum(ErrorCode.process_exited));
    try testing.expectEqual(@as(i64, -32004), @intFromEnum(ErrorCode.timeout));
    try testing.expectEqualStrings("Method not found", ErrorCode.method_not_found.defaultMessage());
    try testing.expectEqualStrings("Unauthorized", ErrorCode.unauthorized.defaultMessage());
    try testing.expectEqualStrings("Process exited", ErrorCode.process_exited.defaultMessage());
    try testing.expectEqualStrings("Timeout", ErrorCode.timeout.defaultMessage());
}

test "에러 모델: 각 표준 코드가 에러 응답으로 직렬화된다" {
    for ([_]ErrorCode{ .parse_error, .invalid_request, .method_not_found, .invalid_params, .internal_error, .payload_too_large, .unauthorized, .process_exited, .timeout }) |code| {
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

test "프레이밍: 미완결 tail이 max_frame 초과하면 next()가 완결 frame 부재 확인 후 PayloadTooLarge(무한 누적 방어)" {
    var f: Framer = .{ .max_frame = 8 };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "12345"); // 5 ≤ 8, 아직 정상.
    try testing.expect(!f.too_large);
    try testing.expect((try f.next()) == null); // 완결 frame 없음, tail 5 ≤ 8 → null
    try f.push(testing.allocator, "6789"); // 누적 9 > 8, 개행 없는 미완결 tail.
    // push는 oversize를 판정하지 않는다(완결 frame 유실 방지 — code-review 반영). 판정은 next()가 한다.
    try testing.expect(!f.too_large);
    try testing.expectError(error.PayloadTooLarge, f.next()); // 완결 frame 없음을 확인한 뒤 oversize tail 거부
    try testing.expect(f.too_large); // 이제 sticky
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

// ── 5b) auth 셀렉터(A2b) 왕복·관대 파싱 ──
test "auth.self: surface_id 있는 셀렉터 왕복 — serialize→parse가 값 보존, 한 줄" {
    const wire = try serializeAuthSelf(testing.allocator, 42, null);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null); // 한 줄 프레임 불변식
    // notification 모양 확인.
    var pm = try parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    try testing.expectEqualStrings(auth_self_method, pm.message.notification.method);
    // parseAuthFrame이 selector를 뽑고, nonce 없이 보낸 프레임은 cap_nonce=null.
    const frame = parseAuthFrame(testing.allocator, wire);
    try testing.expectEqual(@as(?u64, 42), frame.selector);
    try testing.expect(frame.cap_nonce == null);
}

test "auth.self: surface_id 없음(null)이면 params 빈 객체 → parseAuthFrame selector null" {
    const wire = try serializeAuthSelf(testing.allocator, null, null);
    defer testing.allocator.free(wire);
    const frame = parseAuthFrame(testing.allocator, wire);
    try testing.expect(frame.selector == null and frame.cap_nonce == null);
}

test "parseAuthFrame 관대 파싱: 다른 method·잘못된 모양·음수·비정수는 selector null" {
    // 다른 method(request)는 셀렉터 아님.
    try testing.expect(parseAuthFrame(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}").selector == null);
    // 손상 JSON.
    try testing.expect(parseAuthFrame(testing.allocator, "{not json").selector == null);
    // auth.self지만 surface_id 음수.
    try testing.expect(parseAuthFrame(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":-1}}").selector == null);
    // auth.self지만 surface_id 문자열.
    try testing.expect(parseAuthFrame(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":\"x\"}}").selector == null);
    // 큰 값(u64 도메인)도 보존.
    try testing.expectEqual(@as(?u64, 9007199254740993), parseAuthFrame(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":9007199254740993}}").selector);
}

test "auth.grant(5f-4a-2): serialize→parse 왕복 + 관대 파싱(비-auth.grant·비-hex는 null)" {
    const nonce: [auth_cap_nonce_len]u8 = [_]u8{0x7C} ** auth_cap_nonce_len;
    const wire = try serializeAuthGrant(testing.allocator, nonce);
    defer testing.allocator.free(wire);
    const parsed = parseAuthGrant(testing.allocator, wire);
    try testing.expect(parsed != null);
    try testing.expect(std.mem.eql(u8, &parsed.?, &nonce)); // 왕복 값 보존
    // 관대 파싱: 다른 method(auth.self)·요청·손상·cap_nonce 부재/비-hex/짧은 hex는 null.
    try testing.expect(parseAuthGrant(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":1}}") == null);
    try testing.expect(parseAuthGrant(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}") == null);
    try testing.expect(parseAuthGrant(testing.allocator, "{not json") == null);
    try testing.expect(parseAuthGrant(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.grant\",\"params\":{}}") == null);
    try testing.expect(parseAuthGrant(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.grant\",\"params\":{\"cap_nonce\":\"zz\"}}") == null);
}

// ── 5c) auth 프레임 cap_nonce(1e — capability nonce 왕복·관대 파싱) ──
test "auth.self cap_nonce: 왕복 — serialize(nonce)→parseAuthFrame이 32바이트 nonce 보존 + selector 병존" {
    const nonce: [auth_cap_nonce_len]u8 = [_]u8{0xAB} ** auth_cap_nonce_len;
    const wire = try serializeAuthSelf(testing.allocator, 42, nonce);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null);
    const frame = parseAuthFrame(testing.allocator, wire);
    try testing.expectEqual(@as(?u64, 42), frame.selector); // selector·nonce 병존
    try testing.expect(frame.cap_nonce != null);
    try testing.expect(std.mem.eql(u8, &frame.cap_nonce.?, &nonce));
}

test "auth.self cap_nonce 관대 파싱: 잘못된 길이·비-hex·비-string은 cap_nonce null(selector는 보존)" {
    // 짧은 hex(길이 불일치) → null, selector는 유효.
    const short = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"surface_id\":7,\"cap_nonce\":\"abcd\"}}";
    const f_short = parseAuthFrame(testing.allocator, short);
    try testing.expectEqual(@as(?u64, 7), f_short.selector);
    try testing.expect(f_short.cap_nonce == null);
    // 올바른 길이지만 비-hex 문자(g) → null.
    const nonhex = "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"cap_nonce\":\"" ++ ("g" ** (2 * auth_cap_nonce_len)) ++ "\"}}";
    try testing.expect(parseAuthFrame(testing.allocator, nonhex).cap_nonce == null);
    // 정수 cap_nonce(비-string) → null.
    try testing.expect(parseAuthFrame(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"auth.self\",\"params\":{\"cap_nonce\":123}}").cap_nonce == null);
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

// code-review max 반영: 완결 유효 frame 뒤에 oversize 미완결 tail이 한 read에 같이 도착해도, next()가 앞의
// 완결 frame을 유실하지 않고 먼저 돌려준 뒤에야 oversize를 거부해야 한다(옛 코드는 push가 too_large를 세워 유실).
test "Framer: 완결 frame 뒤 oversize 미완결 tail이 와도 앞 frame을 유실하지 않는다" {
    var f = Framer{ .max_frame = 16 };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "hello\n");
    try f.push(testing.allocator, "0123456789ABCDEFGHIJ"); // 20 > 16, 개행 없는 미완결 tail

    try testing.expectEqualStrings("hello", (try f.next()).?); // 앞 frame 먼저 정상 반환
    try testing.expectError(error.PayloadTooLarge, f.next()); // 그다음에야 oversize tail 거부
    try testing.expectError(error.PayloadTooLarge, f.next()); // sticky
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// 계약 고정: JSON-RPC §1 "notification = id member 없는 Request"이므로, **명시적 `id:null`은 notification이 아니라
// null id를 가진 request**다(member 부재 ≠ member=null). classify가 obj.get("id")의 존재(std.json은 명시 null을
// `.null` Value로 저장)로 request/notification을 가르는 분기를 못박는다 — 이 구분이 무너지면 라우터가 응답 없는
// notification으로 오분류해 조회가 조용히 사라진다(1d dispatchReadOnly는 request만 디스패치).
test "classify: 명시적 id:null은 notification이 아니라 null id request(member 부재 ≠ null)" {
    var pm = try parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"sessions.list\"}");
    defer pm.deinit();
    try testing.expect(pm.message == .request); // notification 아님.
    try testing.expect(pm.message.request.id == .null);
    try testing.expectEqualStrings("sessions.list", pm.message.request.method);

    // 대조: id member 자체가 없으면 notification.
    var nt = try parseMessage(testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"sessions.list\"}");
    defer nt.deinit();
    try testing.expect(nt.message == .notification);

    // null id request가 serialize→parse 왕복에서 request·null id로 보존된다("id":null이 실린다).
    const wire = try serializeMessage(testing.allocator, pm.message);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "\"id\":null") != null);
    var rt = try parseMessage(testing.allocator, wire);
    defer rt.deinit();
    try testing.expect(rt.message == .request);
    try testing.expect(rt.message.request.id == .null);
}

// 에러 응답의 optional `data`(§5.1)는 parse가 `err.data`로 담고 serialize가 다시 싣는다 — 기존 테스트는 전부
// data=null이라 이 왕복(serialize의 `if (e.data)` 분기 + parse의 `.data = eo.get("data")`)이 안 밟혔다.
test "error data: 에러 응답의 optional data(불투명 JSON)가 parse→serialize→parse 왕복에서 보존된다" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Payload too large","data":{"limit":1048576}}}
    ;
    var pm = try parseMessage(testing.allocator, raw);
    defer pm.deinit();
    try testing.expect(pm.message.response.err.?.data != null);
    try testing.expectEqual(@as(i64, 1048576), pm.message.response.err.?.data.?.object.get("limit").?.integer);

    const wire = try serializeMessage(testing.allocator, pm.message);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "\"data\"") != null);
    var pm2 = try parseMessage(testing.allocator, wire);
    defer pm2.deinit();
    try testing.expectEqual(@as(i64, 1048576), pm2.message.response.err.?.data.?.object.get("limit").?.integer);
}
