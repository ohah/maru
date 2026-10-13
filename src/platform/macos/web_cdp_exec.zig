//! Chromium(OSR) 탭의 `browser.executeScript`(W9a② — WebKit 탭에 있던 것을 Chromium 으로). `web_cdp_ops.Op` 가 이 종류를 여기로 넘긴다
//! (같은 `Step`·`Reply` — 보내기·받기·완료는 `app_host_abi`). 계획과 실측은 docs/plans/web-osr-backend.md 「W9a」.
//!
//! - `Runtime.evaluate {expression, awaitPromise, returnByValue, allowUnsafeEvalBlockedByCSP:false, objectGroup}` 한 번 — 식은
//!   `(async (args) => (\n SRC \n))(ARGS)`. 엄격 CSP 에서 안쪽 `eval`·`new Function` 은 WebKit 처럼 막힌다(실측 — 기본값은 허락했다).
//!   문법 사전 검사는 없다(WebKit 의 JSC 검사는 `a=1`·`x=>x`·`await 1` 을 거절했다 — 작성자 선택 D4): 컴파일 오류도 실행 오류처럼
//!   `kind:"execution", name:"SyntaxError"` 다.
//! - 결과 값은 V8 의 by-value(페이지가 바꾼 내장 함수를 타지 않는다 — 계획 공격 1 회차: 페이지 world 의 WebKit 직렬화기 사본은 `join` 을
//!   탔다). Zig 가 **나무를 만들지 않고** 토큰으로 걸어 엄격 JSON 으로 다시 쓴다(`\uXXXX` 를 UTF-8 로 — WebKit 처럼 바이트를 센다,
//!   깊이 128). 최상위 `undefined` 는 WebKit 과 같이 `null`, `unserializableValue`(-0·NaN·Infinity·BigInt)는 WebKit 과 같이
//!   serialization 오류. 안쪽 값의 차이(NaN→null·`{a:undefined}`→`{}`·함수→`{}`)는 문서 표에.
//! - 던진 값은 `Runtime.callFunctionOn` 으로 WebKit 의 `diagnostic()` 과 같은 이름·메시지·stack 을 읽는다(exceptionDetails 의 글은
//!   100 자에서 잘리고 DOMException 은 이름이 없다 — 3 회차 실측). 모든 원격 객체는 묶음 `maru-exec-<id>` 에 두고 끝에 놓는다(묶음 없이
//!   던진 값이 이동까지 남았다 — 힙 0.6→288 MB).
//! - 시작할 때 그 탭의 DevTools 자리 둘이 비어 있어야 한다(`Kick.reserve` — 하나는 terminate 몫). 시한에는 부른 쪽이
//!   `Runtime.terminateExecution` 을 보내고(`terminated`), 그 뒤 온 답은 결과가 아니다. 대화상자 중에는 terminate 를 보내지 않는다(답한
//!   뒤 나머지 스크립트를 죽였다 — 3 회차).

const std = @import("std");
const ops = @import("web_cdp_ops.zig");

const Step = ops.Step;
const Reply = ops.Reply;
const Status = ops.Status;

/// DevTools 호출 인자 상한(sidecar 와 같다 — `app_host_abi` 가 컴파일 때 맞춘다). 식·args 를 JSON 으로 이스케이프한 뒤의 크기다.
pub const max_params_bytes: usize = 64 * 1024;
/// 결과 값의 깊이 상한(WebKit 의 `depthLimit` 과 같다 — 뿌리 컨테이너가 0).
pub const max_result_depth: usize = 128;
/// 오류 진단 payload 상한(WebKit 의 `maxScriptErrorPayloadBytes` 와 같다 — `app_host_abi` 가 컴파일 때 맞춘다).
pub const max_error_payload_bytes: usize = 24 * 1024;
pub const name_max_escaped_bytes: usize = 258;
pub const message_max_escaped_bytes: usize = 16 * 1024 + 2;
/// 자리가 없어 보내지 못했을 때 다시 보내는 간격·횟수(누르기 직후의 kick 이 둘째 자리를 쥐고 있을 수 있다 — 3 초쯤).
pub const busy_retry_ms: u32 = 100;
pub const max_busy_retries: u8 = 45;

pub const script_too_large = "the script is too large for a Chromium tab (64 KiB after JSON escaping, args included)";
pub const paused_at_dialog = "the script is paused at a dialog (alert, confirm or prompt) in that tab; it continues after the user answers — do not run it again";
pub const not_strict_json = "result is not strict JSON";
pub const navigation_name = "Maru.Browser.Navigation(1)";
pub const navigation_message = "the page navigated or closed before the script finished";
pub const unreadable = "the script result could not be read";

/// 묶음 이름의 접두(뒤에 요청 번호).
const group_prefix = "maru-exec-";

/// 던진 값의 이름·메시지·stack 을 읽는 함수(WebKit `diagnostic()` 과 같은 규칙 — getter 가 던져도 멈추지 않는다).
const diagnostic_fn = "function(){var n='<unavailable>',m='<unavailable>',s='';try{n=this&&this.name!==undefined?this.name:'Error'}catch(_){}try{m=this&&this.message!==undefined?this.message:this}catch(_){}try{s=this&&this.stack!==undefined?this.stack:''}catch(_){}function t(v){try{return typeof v==='string'?v:String(v)}catch(_){return '<unavailable>'}}return[t(n),t(m),t(s)]}";

const Stage = enum { evaluate, diagnose, release };

/// 끝에서 어떻게 답하는가 — `app_host_abi.finishCdp` 가 본다.
pub const Delivery = enum {
    /// 보통의 status·result(실패·시한).
    plain,
    /// 엄격 JSON 결과(≤ 512 KiB inline, 넘으면 조각 — `completeCdpResult`).
    result,
    /// 진단 payload(`complete_browser_script_error`, -32006).
    script_error,
    /// 결과가 DevTools 상한(16 MiB)을 넘었다(`complete_browser_result_too_large`).
    too_large,
};

pub const Op = struct {
    id: u64,
    stage: Stage = .evaluate,
    /// evaluate 의 인자(소유 — 다시 보낼 수 있다).
    params: []u8,
    /// 원격 객체 묶음 이름(소유).
    group: []u8,
    max_result_bytes: usize,
    now_ms: i64 = 0,
    retries: u8 = 0,
    /// evaluate 를 보냈다(답을 기다린다) — 그 뒤의 철회에도 묶음은 놓는다.
    sent: bool = false,
    /// 부른 쪽이 시한에 terminate 를 보냈다 — 이제 오는 답은 결과가 아니다.
    terminated: bool = false,
    /// 놓은 뒤에 답할 것.
    outcome: Outcome = .none,
    /// 끝의 전달 방식(`done` 을 돌려줄 때 정한다).
    delivery: Delivery = .plain,

    pub const Outcome = union(enum) {
        none,
        /// 엄격 JSON(소유).
        result: []u8,
        /// 진단 payload(소유).
        script_error: []u8,
        too_large,
        timeout,
        failed: []const u8,
    };

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        gpa.free(self.params);
        gpa.free(self.group);
        self.dropOutcome(gpa);
        self.* = undefined;
    }

    fn dropOutcome(self: *Op, gpa: std.mem.Allocator) void {
        switch (self.outcome) {
            .result, .script_error => |b| gpa.free(b),
            else => {},
        }
        self.outcome = .none;
    }

    /// `arg` 는 L2 가 만든 `{script, args, max_result_bytes}`.
    pub fn init(gpa: std.mem.Allocator, arg: []const u8, id: u64) !Op {
        const parsed = std.json.parseFromSlice(struct { script: []const u8, args: []const std.json.Value = &.{}, max_result_bytes: usize }, gpa, arg, .{ .ignore_unknown_fields = true }) catch return error.InvalidArg;
        defer parsed.deinit();
        const group = try std.fmt.allocPrint(gpa, group_prefix ++ "{d}", .{id});
        errdefer gpa.free(group);
        const params = try buildParams(gpa, parsed.value.script, parsed.value.args, group);
        errdefer gpa.free(params);
        if (params.len > max_params_bytes) return error.ScriptTooLarge;
        return .{ .id = id, .params = params, .group = group, .max_result_bytes = parsed.value.max_result_bytes };
    }

    pub fn committed(self: *const Op) bool {
        return self.stage == .release;
    }

    /// 철회됐다 — evaluate 를 보냈으면 묶음을 놓은 뒤 끝낸다, 아니면 그냥 끝낸다(null).
    pub fn cancel(self: *Op, gpa: std.mem.Allocator) !?Step {
        if (!self.sent or self.stage == .release) return null;
        self.dropOutcome(gpa);
        self.outcome = .{ .failed = "the request was cancelled" };
        return try self.releaseStep(gpa);
    }

    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        return self.evaluateStep(gpa);
    }

    /// 자리가 없어 못 보낸 evaluate 를 다시.
    pub fn wake(self: *Op, gpa: std.mem.Allocator) !Step {
        return self.evaluateStep(gpa);
    }

    fn evaluateStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .evaluate;
        // 둘째 자리는 시한의 terminate 몫 — 둘 다 비어 있어야 보낸다(kick 은 붙이지 않는다).
        return .{ .call = .{ .method = "Runtime.evaluate", .params = try gpa.dupe(u8, self.params), .kick = .reserve } };
    }

    fn releaseStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .release;
        return .{ .call = .{ .method = "Runtime.releaseObjectGroup", .params = try std.fmt.allocPrint(gpa, "{{\"objectGroup\":\"{s}\"}}", .{self.group}) } };
    }

    fn diagnoseStep(self: *Op, gpa: std.mem.Allocator, object_id: []const u8) !Step {
        self.stage = .diagnose;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("objectId") catch return error.OutOfMemory;
        s.write(object_id) catch return error.OutOfMemory;
        s.objectField("functionDeclaration") catch return error.OutOfMemory;
        s.write(diagnostic_fn) catch return error.OutOfMemory;
        s.objectField("returnByValue") catch return error.OutOfMemory;
        s.write(true) catch return error.OutOfMemory;
        s.objectField("objectGroup") catch return error.OutOfMemory;
        s.write(self.group) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Runtime.callFunctionOn", .params = try aw.toOwnedSlice() } };
    }

    fn finish(self: *Op, gpa: std.mem.Allocator) !Step {
        const out = self.outcome;
        self.outcome = .none; // 소유를 `done` 으로 넘긴다
        return switch (out) {
            .none => done(gpa, .failed, "internal DevTools request error"),
            .result => |b| blk: {
                self.delivery = .result;
                break :blk .{ .done = .{ .status = .success, .result = b } };
            },
            .script_error => |b| blk: {
                self.delivery = .script_error;
                break :blk .{ .done = .{ .status = .success, .result = b } };
            },
            .too_large => blk: {
                self.delivery = .too_large;
                break :blk done(gpa, .success, "");
            },
            .timeout => done(gpa, .timeout, "the script did not finish in time (it was stopped)"),
            .failed => |why| done(gpa, .failed, why),
        };
    }

    fn setOutcome(self: *Op, gpa: std.mem.Allocator, outcome: Outcome) void {
        self.dropOutcome(gpa);
        self.outcome = outcome;
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        switch (self.stage) {
            .release => return self.finish(gpa), // 놓기의 답은 무엇이든
            .diagnose => {
                const payload = switch (reply) {
                    .ok => |body| diagnosePayload(gpa, body),
                    else => errorPayload(gpa, "execution", "<unavailable>", "<unavailable>", ""),
                } catch return error.OutOfMemory;
                self.setOutcome(gpa, .{ .script_error = payload });
                return self.releaseStep(gpa);
            },
            .evaluate => {},
        }
        switch (reply) {
            .not_sent => |why| {
                // 자리가 없다 — 잠깐 뒤 다시(누르기 직후의 kick 이 둘째 자리를 쥐고 있을 수 있다). 그 밖은 보내지 않은 것이라 곧 실패.
                if (std.mem.eql(u8, why, ops.busy_reason) and self.retries < max_busy_retries) {
                    self.retries += 1;
                    return .{ .sleep = busy_retry_ms };
                }
                return done(gpa, .failed, why);
            },
            .failed => |why| {
                self.sent = true;
                if (self.terminated) {
                    self.setOutcome(gpa, .timeout);
                } else if (std.mem.eql(u8, why, ops.dialog_reason)) {
                    // 스크립트가 대화상자를 띄웠다 — 호출은 사용자가 답할 때까지 막힌다(terminate 도 안 듣는다). 놓기는 web_osr 가 미룬다.
                    self.setOutcome(gpa, .{ .failed = paused_at_dialog });
                } else if (std.mem.eql(u8, why, ops.result_too_large)) {
                    self.setOutcome(gpa, .too_large);
                } else {
                    self.setOutcome(gpa, .{ .failed = why });
                }
                return self.releaseStep(gpa);
            },
            .timed_out => {
                self.sent = true;
                self.setOutcome(gpa, .timeout);
                return self.releaseStep(gpa);
            },
            .cdp_error => |e| {
                self.sent = true;
                if (self.terminated) {
                    self.setOutcome(gpa, .timeout);
                } else {
                    const msg = cdpMessage(e);
                    const payload = if (std.mem.indexOf(u8, msg, "navigated or closed") != null or std.mem.indexOf(u8, msg, "context was destroyed") != null)
                        try errorPayload(gpa, "navigation", navigation_name, navigation_message, "")
                    else
                        // "Object couldn't be returned by value"·"Object reference chain is too long"·"Internal error"(던지는 getter·Proxy) — 값이 아니다.
                        try errorPayload(gpa, "serialization", "TypeError", not_strict_json, "");
                    self.setOutcome(gpa, .{ .script_error = payload });
                }
                return self.releaseStep(gpa);
            },
            .ok => |body| {
                self.sent = true;
                if (self.terminated) {
                    self.setOutcome(gpa, .timeout);
                    return self.releaseStep(gpa);
                }
                var an = analyze(gpa, body) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        self.setOutcome(gpa, .{ .failed = unreadable });
                        return self.releaseStep(gpa);
                    },
                };
                defer an.deinit(gpa);
                switch (an.kind) {
                    .exception => {
                        if (an.exception_object_id) |oid| return self.diagnoseStep(gpa, oid);
                        self.setOutcome(gpa, .{ .script_error = try primitiveExceptionPayload(gpa, an) });
                    },
                    .undefined_value => self.setOutcome(gpa, .{ .result = try gpa.dupe(u8, "null") }),
                    .unserializable => self.setOutcome(gpa, .{ .script_error = try errorPayload(gpa, "serialization", "TypeError", not_strict_json, "") }),
                    .value => {
                        const rewritten = rewriteValue(gpa, an.value) catch |e| switch (e) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.TooDeep => {
                                self.setOutcome(gpa, .{ .script_error = try errorPayload(gpa, "serialization", "TypeError", not_strict_json, "") });
                                return self.releaseStep(gpa);
                            },
                            else => {
                                self.setOutcome(gpa, .{ .failed = unreadable });
                                return self.releaseStep(gpa);
                            },
                        };
                        self.setOutcome(gpa, .{ .result = rewritten });
                    },
                }
                return self.releaseStep(gpa);
            },
        }
    }
};

// ── 인자 만들기 ───────────────────────────────────────────────────────────────────────────────────────────

fn buildParams(gpa: std.mem.Allocator, script: []const u8, args: []const std.json.Value, group: []const u8) ![]u8 {
    var expr: std.Io.Writer.Allocating = .init(gpa);
    defer expr.deinit();
    try expr.writer.writeAll("(async (args) => (\n");
    try expr.writer.writeAll(script);
    try expr.writer.writeAll("\n))(");
    try writeArgsLiteral(&expr.writer, args);
    try expr.writer.writeAll(")");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("expression") catch return error.OutOfMemory;
    s.write(expr.written()) catch return error.OutOfMemory;
    s.objectField("awaitPromise") catch return error.OutOfMemory;
    s.write(true) catch return error.OutOfMemory;
    s.objectField("returnByValue") catch return error.OutOfMemory;
    s.write(true) catch return error.OutOfMemory;
    // 엄격 CSP 에서 안쪽 eval 을 WebKit 처럼 막는다(기본값은 허락했다 — 계획 공격 1 회차).
    s.objectField("allowUnsafeEvalBlockedByCSP") catch return error.OutOfMemory;
    s.write(false) catch return error.OutOfMemory;
    s.objectField("objectGroup") catch return error.OutOfMemory;
    s.write(group) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// args 배열을 JS 배열 리터럴로 — JSON 과 같되 `__proto__` 키는 계산된 키(`["__proto__"]:`)로(리터럴의 `__proto__:` 는 프로토타입을
/// 바꾼다 — 계획 공격 3 회차).
fn writeArgsLiteral(w: *std.Io.Writer, args: []const std.json.Value) !void {
    try w.writeByte('[');
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsValue(w, a);
    }
    try w.writeByte(']');
}

fn writeJsValue(w: *std.Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .object => |o| {
            try w.writeByte('{');
            var first = true;
            var it = o.iterator();
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                if (std.mem.eql(u8, e.key_ptr.*, "__proto__")) try w.writeByte('[');
                try std.json.Stringify.encodeJsonString(e.key_ptr.*, .{}, w);
                if (std.mem.eql(u8, e.key_ptr.*, "__proto__")) try w.writeByte(']');
                try w.writeByte(':');
                try writeJsValue(w, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsValue(w, item);
            }
            try w.writeByte(']');
        },
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

// ── 답 읽기 ───────────────────────────────────────────────────────────────────────────────────────────────

const Analysis = struct {
    kind: enum { value, undefined_value, unserializable, exception },
    /// `result.value` 의 바이트(body 를 빌린다 — V8 의 압축 JSON).
    value: []const u8 = "",
    /// 던진 값이 객체면 그 objectId(소유).
    exception_object_id: ?[]u8 = null,
    /// 던진 값이 원시 값이면 그 글(소유 — String(값)).
    exception_text: ?[]u8 = null,

    fn deinit(self: *Analysis, gpa: std.mem.Allocator) void {
        if (self.exception_object_id) |s| gpa.free(s);
        if (self.exception_text) |s| gpa.free(s);
    }
};

/// `Runtime.evaluate` 의 답을 나무로 풀지 않고 읽는다 — 16 MiB 결과를 `std.json.Value` 로 풀면 0.15–0.37 초·0.45–1.5 GB 였다(3 회차).
/// `result.value` 는 자리만 잡고(아래 `rewriteValue` 가 다시 쓴다), `exceptionDetails` 만 작은 나무로 푼다.
fn analyze(gpa: std.mem.Allocator, body: []const u8) !Analysis {
    var sc = std.json.Scanner.initCompleteInput(gpa, body);
    defer sc.deinit();
    if (try sc.next() != .object_begin) return error.Unexpected;
    var value_range: ?[]const u8 = null;
    var type_undefined = false;
    var unserializable = false;
    var exception_range: ?[]const u8 = null;
    while (true) {
        const tok = try sc.nextAlloc(gpa, .alloc_if_needed);
        switch (tok) {
            .object_end => break,
            .string, .allocated_string => |key| {
                defer if (tok == .allocated_string) gpa.free(tok.allocated_string);
                if (std.mem.eql(u8, key, "result")) {
                    if (try sc.next() != .object_begin) return error.Unexpected;
                    while (true) {
                        const rt = try sc.nextAlloc(gpa, .alloc_if_needed);
                        switch (rt) {
                            .object_end => break,
                            .string, .allocated_string => |rk| {
                                defer if (rt == .allocated_string) gpa.free(rt.allocated_string);
                                if (std.mem.eql(u8, rk, "value")) {
                                    value_range = try skipValueRange(&sc, body);
                                } else if (std.mem.eql(u8, rk, "type")) {
                                    const tt = try sc.nextAlloc(gpa, .alloc_if_needed);
                                    defer if (tt == .allocated_string) gpa.free(tt.allocated_string);
                                    switch (tt) {
                                        .string, .allocated_string => |t| type_undefined = std.mem.eql(u8, t, "undefined"),
                                        else => return error.Unexpected,
                                    }
                                } else if (std.mem.eql(u8, rk, "unserializableValue")) {
                                    unserializable = true;
                                    try sc.skipValue();
                                } else try sc.skipValue();
                            },
                            else => return error.Unexpected,
                        }
                    }
                } else if (std.mem.eql(u8, key, "exceptionDetails")) {
                    exception_range = try skipValueRange(&sc, body);
                } else try sc.skipValue();
            },
            else => return error.Unexpected,
        }
    }
    if (exception_range) |ex| return exceptionAnalysis(gpa, ex);
    if (unserializable) return .{ .kind = .unserializable };
    if (type_undefined) return .{ .kind = .undefined_value };
    const v = value_range orelse return error.Unexpected;
    return .{ .kind = .value, .value = v };
}

/// 키 뒤의 값을 넘기고 그 바이트 자리를 돌려준다(`:` 와 공백을 뺀다).
fn skipValueRange(sc: *std.json.Scanner, body: []const u8) ![]const u8 {
    const start = sc.cursor;
    try sc.skipValue();
    var raw = body[start..sc.cursor];
    raw = std.mem.trimStart(u8, raw, " \t\r\n");
    if (raw.len > 0 and raw[0] == ':') raw = raw[1..];
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// `exceptionDetails` — 던진 값이 객체면 objectId, 원시 값이면 String(값)(WebKit: name 'Error', message 는 그 값).
fn exceptionAnalysis(gpa: std.mem.Allocator, range: []const u8) !Analysis {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, range, .{}) catch return error.Unexpected;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Unexpected;
    const ex = parsed.value.object.get("exception") orelse return .{ .kind = .exception, .exception_text = try gpa.dupe(u8, "<unavailable>") };
    if (ex != .object) return error.Unexpected;
    if (ex.object.get("objectId")) |oid| if (oid == .string) return .{ .kind = .exception, .exception_object_id = try gpa.dupe(u8, oid.string) };
    const text: []u8 = blk: {
        if (ex.object.get("unserializableValue")) |u| if (u == .string) {
            // BigInt 는 `10n` — WebKit 의 String(10n) 은 "10".
            const s = u.string;
            break :blk try gpa.dupe(u8, if (s.len > 1 and s[s.len - 1] == 'n') s[0 .. s.len - 1] else s);
        };
        if (ex.object.get("value")) |v| switch (v) {
            .string => |s| break :blk try gpa.dupe(u8, s),
            .null => break :blk try gpa.dupe(u8, "null"),
            .bool => |b| break :blk try gpa.dupe(u8, if (b) "true" else "false"),
            .integer, .float, .number_string => break :blk try std.json.Stringify.valueAlloc(gpa, v, .{}),
            else => {},
        };
        if (ex.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "undefined")) break :blk try gpa.dupe(u8, "undefined");
        if (ex.object.get("description")) |d| if (d == .string) break :blk try gpa.dupe(u8, d.string);
        break :blk try gpa.dupe(u8, "<unavailable>");
    };
    return .{ .kind = .exception, .exception_text = text };
}

fn primitiveExceptionPayload(gpa: std.mem.Allocator, an: Analysis) ![]u8 {
    return errorPayload(gpa, "execution", "Error", an.exception_text orelse "<unavailable>", "");
}

/// `Runtime.callFunctionOn` 의 답 `{"result":{"type":"object","value":[name,message,stack]}}` → 진단 payload.
fn diagnosePayload(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(struct { result: struct { value: ?[]const std.json.Value = null } }, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return errorPayload(gpa, "execution", "<unavailable>", "<unavailable>", "");
    defer parsed.deinit();
    const v = parsed.value.result.value orelse return errorPayload(gpa, "execution", "<unavailable>", "<unavailable>", "");
    if (v.len != 3) return errorPayload(gpa, "execution", "<unavailable>", "<unavailable>", "");
    const name = if (v[0] == .string) v[0].string else "<unavailable>";
    const message = if (v[1] == .string) v[1].string else "<unavailable>";
    const stack = if (v[2] == .string) v[2].string else "";
    return errorPayload(gpa, "execution", name, message, stack);
}

/// 이스케이프한 뒤의 바이트가 `cap` 안에 드는 앞부분(코드 포인트 경계)과 잘렸는지 — WebKit `escapedDiagnostic` 과 같은 셈법(따옴표 둘 포함).
fn clipEscaped(s: []const u8, cap: usize) struct { text: []const u8, truncated: bool } {
    var used: usize = 2;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + len, s.len);
        const c = s[i];
        const cost: usize = if (c == '"' or c == '\\' or c == 0x08 or c == 0x09 or c == 0x0a or c == 0x0c or c == 0x0d) 2 else if (c < 0x20) 6 else end - i;
        if (used + cost > cap) return .{ .text = s[0..i], .truncated = true };
        used += cost;
        i = end;
    }
    return .{ .text = s, .truncated = false };
}

/// WebKit 과 같은 진단 payload `{kind, name, message, stack, diagnostics_truncated}`(≤ 24 KiB — stack 이 남는 자리를 쓴다).
pub fn errorPayload(gpa: std.mem.Allocator, kind: []const u8, name: []const u8, message: []const u8, stack: []const u8) ![]u8 {
    const n = clipEscaped(name, name_max_escaped_bytes);
    const m = clipEscaped(message, message_max_escaped_bytes);
    const fixed = "{\"kind\":\"\",\"name\":".len + kind.len + ",\"message\":".len + ",\"stack\":".len + ",\"diagnostics_truncated\":false}".len + escapedLen(n.text) + escapedLen(m.text);
    const remaining = if (max_error_payload_bytes > fixed + 40) max_error_payload_bytes - fixed - 40 else 2;
    const st = clipEscaped(stack, @max(remaining, 2));
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("kind") catch return error.OutOfMemory;
    s.write(kind) catch return error.OutOfMemory;
    s.objectField("name") catch return error.OutOfMemory;
    s.write(n.text) catch return error.OutOfMemory;
    s.objectField("message") catch return error.OutOfMemory;
    s.write(m.text) catch return error.OutOfMemory;
    s.objectField("stack") catch return error.OutOfMemory;
    s.write(st.text) catch return error.OutOfMemory;
    s.objectField("diagnostics_truncated") catch return error.OutOfMemory;
    s.write(n.truncated or m.truncated or st.truncated) catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn escapedLen(s: []const u8) usize {
    var n: usize = 2;
    for (s) |c| n += if (c == '"' or c == '\\' or c == 0x08 or c == 0x09 or c == 0x0a or c == 0x0c or c == 0x0d) 2 else if (c < 0x20) 6 else 1;
    return n;
}

/// V8 의 값(압축 JSON)을 엄격 JSON 으로 다시 쓴다 — 나무 없이 토큰으로: 문자열의 `\uXXXX` 는 UTF-8 로(WebKit 과 같은 바이트 셈),
/// 숫자 lexeme 은 그대로, 깊이는 `max_result_depth`(뿌리 컨테이너 0) 를 넘으면 `TooDeep`.
pub fn rewriteValue(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var sc = std.json.Scanner.initCompleteInput(gpa, value);
    defer sc.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    // 컨테이너마다 객체인가(객체면 문자열이 키·값으로 번갈아 온다).
    var objects: std.ArrayList(bool) = .empty;
    defer objects.deinit(gpa);
    var key_next = false;
    while (true) {
        const tok = try sc.nextAlloc(gpa, .alloc_if_needed);
        switch (tok) {
            .object_begin => {
                if (sc.stackHeight() > max_result_depth + 1) return error.TooDeep;
                s.beginObject() catch return error.OutOfMemory;
                try objects.append(gpa, true);
                key_next = true;
            },
            .array_begin => {
                if (sc.stackHeight() > max_result_depth + 1) return error.TooDeep;
                s.beginArray() catch return error.OutOfMemory;
                try objects.append(gpa, false);
                key_next = false;
            },
            .object_end => {
                s.endObject() catch return error.OutOfMemory;
                _ = objects.pop();
                key_next = objects.getLastOrNull() orelse false;
            },
            .array_end => {
                s.endArray() catch return error.OutOfMemory;
                _ = objects.pop();
                key_next = objects.getLastOrNull() orelse false;
            },
            .string, .allocated_string => |str| {
                defer if (tok == .allocated_string) gpa.free(tok.allocated_string);
                if (key_next) {
                    s.objectField(str) catch return error.OutOfMemory;
                    key_next = false;
                } else {
                    s.write(str) catch return error.OutOfMemory;
                    key_next = objects.getLastOrNull() orelse false;
                }
            },
            .number, .allocated_number => |num| {
                defer if (tok == .allocated_number) gpa.free(tok.allocated_number);
                s.print("{s}", .{num}) catch return error.OutOfMemory;
                key_next = objects.getLastOrNull() orelse false;
            },
            .true => {
                s.write(true) catch return error.OutOfMemory;
                key_next = objects.getLastOrNull() orelse false;
            },
            .false => {
                s.write(false) catch return error.OutOfMemory;
                key_next = objects.getLastOrNull() orelse false;
            },
            .null => {
                s.write(null) catch return error.OutOfMemory;
                key_next = objects.getLastOrNull() orelse false;
            },
            .end_of_document => break,
            .partial_number, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => unreachable, // nextAlloc 은 완전한 토큰만
        }
    }
    return aw.toOwnedSlice();
}

/// CDP 오류 `{"code":…,"message":"…"}` 의 message(없으면 그대로).
fn cdpMessage(e: []const u8) []const u8 {
    const key = "\"message\":\"";
    const at = std.mem.indexOf(u8, e, key) orelse return e;
    const rest = e[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return e;
    return rest[0..end];
}

fn done(gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
    return .{ .done = .{ .status = status, .result = try gpa.dupe(u8, result) } };
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn argJson(script: []const u8, args: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "{{\"script\":{f},\"args\":{s},\"max_result_bytes\":1048576}}", .{ std.json.fmt(script, .{}), args });
}

/// evaluate 까지 간 op — 그 인자(expression)를 돌려준다.
fn evaluated(op: *Op) ![]u8 {
    const step = try op.start(testing.allocator);
    try testing.expectEqualStrings("Runtime.evaluate", step.call.method);
    try testing.expect(step.call.kick == .reserve);
    return step.call.params;
}

fn expectRelease(step: Step) !void {
    defer testing.allocator.free(step.call.params);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", step.call.method);
    try testing.expect(std.mem.indexOf(u8, step.call.params, group_prefix) != null);
}

fn finishOp(op: *Op) !Step {
    return op.feed(testing.allocator, .{ .ok = "{}" });
}

test "W9a② 인자: 식은 async 화살표에 싸이고 args 는 리터럴(__proto__ 는 계산된 키), CSP 의 eval 은 막고, 묶음을 둔다 — 64 KiB 를 넘으면 거절" {
    const gpa = testing.allocator;
    {
        const arg = try argJson("1 + args[0].a", "[{\"a\":2,\"__proto__\":{\"x\":1}},\"s\\\"q\",null,true,1.5]");
        defer gpa.free(arg);
        var op = try Op.init(gpa, arg, 7);
        defer op.deinit(gpa);
        const p = try evaluated(&op);
        defer gpa.free(p);
        const parsed = try std.json.parseFromSlice(struct { expression: []const u8, awaitPromise: bool, returnByValue: bool, allowUnsafeEvalBlockedByCSP: bool, objectGroup: []const u8 }, gpa, p, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("(async (args) => (\n1 + args[0].a\n))([{\"a\":2,[\"__proto__\"]:{\"x\":1}},\"s\\\"q\",null,true,1.5])", parsed.value.expression);
        try testing.expect(parsed.value.awaitPromise and parsed.value.returnByValue and !parsed.value.allowUnsafeEvalBlockedByCSP);
        try testing.expectEqualStrings("maru-exec-7", parsed.value.objectGroup);
        try testing.expectEqual(@as(usize, 1048576), op.max_result_bytes);
    }
    {
        const big = try gpa.alloc(u8, 70 * 1024);
        defer gpa.free(big);
        @memset(big, 'x');
        const arg = try argJson(big, "[]");
        defer gpa.free(arg);
        try testing.expectError(error.ScriptTooLarge, Op.init(gpa, arg, 1));
        // 이스케이프가 키운다 — 40 KiB 의 따옴표는 80 KiB.
        const quotes = try gpa.alloc(u8, 40 * 1024);
        defer gpa.free(quotes);
        @memset(quotes, '"');
        const arg2 = try argJson(quotes, "[]");
        defer gpa.free(arg2);
        try testing.expectError(error.ScriptTooLarge, Op.init(gpa, arg2, 1));
    }
    try testing.expectError(error.InvalidArg, Op.init(gpa, "{\"script\":1}", 1));
}

test "W9a② 결과: V8 by-value 를 엄격 JSON 으로 — undefined 는 null, \\u 이스케이프는 UTF-8, 숫자는 그대로, 묶음은 끝에 놓는다" {
    const gpa = testing.allocator;
    const arg = try argJson("x", "[]");
    defer gpa.free(arg);
    const cases = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "{\"result\":{\"type\":\"object\",\"value\":{\"a\":[1,2,\"x\"],\"k\":\"\\ud55c\\uae00\",\"n\":1.2345678901234567e+19,\"e\":{},\"q\":\"\\\"\\\\\"}}}", .want = "{\"a\":[1,2,\"x\"],\"k\":\"한글\",\"n\":1.2345678901234567e+19,\"e\":{},\"q\":\"\\\"\\\\\"}" },
        .{ .body = "{\"result\":{\"type\":\"undefined\"}}", .want = "null" },
        .{ .body = "{\"result\":{\"type\":\"number\",\"value\":-1}}", .want = "-1" },
        .{ .body = "{\"result\":{\"type\":\"string\",\"value\":\"s\"}}", .want = "\"s\"" },
        .{ .body = "{\"result\":{\"type\":\"object\",\"subtype\":\"null\",\"value\":null}}", .want = "null" },
        .{ .body = "{\"result\":{\"value\":[true,false,null,[]],\"type\":\"object\"}}", .want = "[true,false,null,[]]" },
    };
    for (cases) |c| {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        try expectRelease(try op.feed(gpa, .{ .ok = c.body }));
        try testing.expect(op.committed());
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Status.success, fin.done.status);
        try testing.expectEqual(Delivery.result, op.delivery);
        try testing.expectEqualStrings(c.want, fin.done.result);
    }
}

test "W9a② 결과가 값이 아니다: unserializableValue·V8 의 by-value 실패·너무 깊은 값은 WebKit 과 같은 serialization 오류" {
    const gpa = testing.allocator;
    const arg = try argJson("x", "[]");
    defer gpa.free(arg);
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    try deep.appendSlice(gpa, "{\"result\":{\"type\":\"object\",\"value\":");
    for (0..130) |_| try deep.appendSlice(gpa, "[");
    for (0..130) |_| try deep.appendSlice(gpa, "]");
    try deep.appendSlice(gpa, "}}");
    const cases = [_]Reply{
        .{ .ok = "{\"result\":{\"type\":\"number\",\"unserializableValue\":\"-0\",\"description\":\"-0\"}}" },
        .{ .ok = "{\"result\":{\"type\":\"bigint\",\"unserializableValue\":\"10n\",\"description\":\"10n\"}}" },
        .{ .cdp_error = "{\"code\":-32000,\"message\":\"Object reference chain is too long\"}" },
        .{ .cdp_error = "{\"code\":-32000,\"message\":\"Object couldn't be returned by value\"}" },
        .{ .cdp_error = "{\"code\":-32603,\"message\":\"Internal error\"}" },
        .{ .ok = deep.items },
    };
    for (cases) |reply| {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        try expectRelease(try op.feed(gpa, reply));
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Delivery.script_error, op.delivery);
        try testing.expectEqualStrings("{\"kind\":\"serialization\",\"name\":\"TypeError\",\"message\":\"result is not strict JSON\",\"stack\":\"\",\"diagnostics_truncated\":false}", fin.done.result);
    }
    // 129 단(뿌리 0 … 128)은 된다.
    var ok_deep: std.ArrayList(u8) = .empty;
    defer ok_deep.deinit(gpa);
    try ok_deep.appendSlice(gpa, "{\"result\":{\"type\":\"object\",\"value\":");
    for (0..129) |_| try ok_deep.appendSlice(gpa, "[");
    for (0..129) |_| try ok_deep.appendSlice(gpa, "]");
    try ok_deep.appendSlice(gpa, "}}");
    var op = try Op.init(gpa, arg, 1);
    defer op.deinit(gpa);
    gpa.free(try evaluated(&op));
    gpa.free((try op.feed(gpa, .{ .ok = ok_deep.items })).call.params);
    const fin = try finishOp(&op);
    defer gpa.free(fin.done.result);
    try testing.expectEqual(Delivery.result, op.delivery);
    try testing.expectEqual(@as(usize, 258), fin.done.result.len);
}

test "W9a② 던진 값: 객체면 두 번째 호출로 이름·메시지·stack 을 읽고(getter 가 던져도), 원시 값이면 WebKit 처럼 name Error·message 는 그 값" {
    const gpa = testing.allocator;
    const arg = try argJson("x", "[]");
    defer gpa.free(arg);
    {
        var op = try Op.init(gpa, arg, 3);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        const diag = try op.feed(gpa, .{ .ok = "{\"result\":{\"type\":\"object\",\"subtype\":\"error\",\"className\":\"Error\",\"description\":\"Error: x\",\"objectId\":\"o-9\"},\"exceptionDetails\":{\"exceptionId\":1,\"text\":\"Uncaught (in promise)\",\"lineNumber\":0,\"columnNumber\":0,\"exception\":{\"type\":\"object\",\"subtype\":\"error\",\"className\":\"Error\",\"description\":\"Error: x\",\"objectId\":\"o-9\"}}}" });
        defer gpa.free(diag.call.params);
        try testing.expectEqualStrings("Runtime.callFunctionOn", diag.call.method);
        try testing.expect(std.mem.indexOf(u8, diag.call.params, "\"objectId\":\"o-9\"") != null);
        try testing.expect(std.mem.indexOf(u8, diag.call.params, "\"objectGroup\":\"maru-exec-3\"") != null);
        try testing.expect(std.mem.indexOf(u8, diag.call.params, "this.name") != null);
        try testing.expect(!op.committed()); // 진단은 철회되면 보내지 않는다(놓기만)
        try expectRelease(try op.feed(gpa, .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":[\"MyErr\",\"boom \\\"q\\\"\",\"MyErr: boom\\n    at <anonymous>:1:1\"]}}" }));
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Delivery.script_error, op.delivery);
        try testing.expectEqualStrings("{\"kind\":\"execution\",\"name\":\"MyErr\",\"message\":\"boom \\\"q\\\"\",\"stack\":\"MyErr: boom\\n    at <anonymous>:1:1\",\"diagnostics_truncated\":false}", fin.done.result);
    }
    const prim = [_]struct { ex: []const u8, want: []const u8 }{
        .{ .ex = "{\"type\":\"string\",\"value\":\"x\"}", .want = "x" },
        .{ .ex = "{\"type\":\"undefined\"}", .want = "undefined" },
        .{ .ex = "{\"type\":\"number\",\"value\":5}", .want = "5" },
        .{ .ex = "{\"type\":\"bigint\",\"unserializableValue\":\"10n\",\"description\":\"10n\"}", .want = "10" },
        .{ .ex = "{\"type\":\"object\",\"subtype\":\"null\",\"value\":null}", .want = "null" },
    };
    for (prim) |c| {
        var op = try Op.init(gpa, arg, 3);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        const body = try std.fmt.allocPrint(gpa, "{{\"result\":{s},\"exceptionDetails\":{{\"exceptionId\":1,\"text\":\"Uncaught (in promise)\",\"exception\":{s}}}}}", .{ c.ex, c.ex });
        defer gpa.free(body);
        try expectRelease(try op.feed(gpa, .{ .ok = body }));
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        const want = try std.fmt.allocPrint(gpa, "{{\"kind\":\"execution\",\"name\":\"Error\",\"message\":\"{s}\",\"stack\":\"\",\"diagnostics_truncated\":false}}", .{c.want});
        defer gpa.free(want);
        try testing.expectEqualStrings(want, fin.done.result);
    }
    // 진단 호출이 실패해도 payload 는 나온다.
    var op = try Op.init(gpa, arg, 3);
    defer op.deinit(gpa);
    gpa.free(try evaluated(&op));
    gpa.free((try op.feed(gpa, .{ .ok = "{\"result\":{\"type\":\"object\",\"objectId\":\"o\"},\"exceptionDetails\":{\"exception\":{\"type\":\"object\",\"objectId\":\"o\"}}}" })).call.params);
    try expectRelease(try op.feed(gpa, .{ .cdp_error = "{\"code\":-32000,\"message\":\"Could not find object\"}" }));
    const fin = try finishOp(&op);
    defer gpa.free(fin.done.result);
    try testing.expect(std.mem.indexOf(u8, fin.done.result, "\"name\":\"<unavailable>\"") != null);
}

test "W9a② 진단 payload 상한: 이름 258·메시지 16 KiB·stack 은 24 KiB 의 남는 자리 — 잘리면 diagnostics_truncated, 코드 포인트 경계에서" {
    const gpa = testing.allocator;
    const long_name = "n" ** 300;
    const korean = "한" ** 6000; // 18 000 바이트
    const stack = "s" ** 30000;
    const p = try errorPayload(gpa, "execution", long_name, korean, stack);
    defer gpa.free(p);
    try testing.expect(p.len <= max_error_payload_bytes);
    const parsed = try std.json.parseFromSlice(struct { kind: []const u8, name: []const u8, message: []const u8, stack: []const u8, diagnostics_truncated: bool }, gpa, p, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 256), parsed.value.name.len);
    try testing.expect(parsed.value.message.len % 3 == 0 and parsed.value.message.len <= 16 * 1024);
    try testing.expect(parsed.value.stack.len > 1000 and parsed.value.diagnostics_truncated);
    const small = try errorPayload(gpa, "navigation", navigation_name, navigation_message, "");
    defer gpa.free(small);
    try testing.expect(std.mem.endsWith(u8, small, "\"diagnostics_truncated\":false}"));
}

test "W9a② 끝의 다른 길: 이동·시한·terminate 뒤의 답·대화상자·너무 큼·자리 없음은 잠깐 뒤 다시·철회" {
    const gpa = testing.allocator;
    const arg = try argJson("x", "[]");
    defer gpa.free(arg);
    {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        try expectRelease(try op.feed(gpa, .{ .cdp_error = "{\"code\":-32000,\"message\":\"Inspected target navigated or closed\"}" }));
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Delivery.script_error, op.delivery);
        try testing.expect(std.mem.startsWith(u8, fin.done.result, "{\"kind\":\"navigation\",\"name\":\"Maru.Browser.Navigation(1)\""));
    }
    {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        try expectRelease(try op.feed(gpa, .{ .timed_out = "x" }));
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Status.timeout, fin.done.status);
        try testing.expectEqual(Delivery.plain, op.delivery);
    }
    {
        // terminate 를 보낸 뒤 온 답(Internal error 든 값이든)은 시한이다.
        for ([_]Reply{ .{ .cdp_error = "{\"code\":-32603,\"message\":\"Internal error\"}" }, .{ .ok = "{\"result\":{\"type\":\"number\",\"value\":1}}" } }) |r| {
            var op = try Op.init(gpa, arg, 1);
            defer op.deinit(gpa);
            gpa.free(try evaluated(&op));
            op.terminated = true;
            try expectRelease(try op.feed(gpa, r));
            const fin = try finishOp(&op);
            defer gpa.free(fin.done.result);
            try testing.expectEqual(Status.timeout, fin.done.status);
        }
    }
    {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        try expectRelease(try op.feed(gpa, .{ .failed = ops.dialog_reason }));
        const fin = try op.feed(gpa, .{ .not_sent = ops.dialog_reason }); // 놓기는 web_osr 가 미뤘다
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Status.failed, fin.done.status);
        try testing.expectEqualStrings(paused_at_dialog, fin.done.result);
    }
    {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        try expectRelease(try op.feed(gpa, .{ .failed = ops.result_too_large }));
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Delivery.too_large, op.delivery);
    }
    {
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        gpa.free(try evaluated(&op));
        var n: usize = 0;
        while (n < max_busy_retries) : (n += 1) {
            try testing.expectEqual(@as(u32, busy_retry_ms), (try op.feed(gpa, .{ .not_sent = ops.busy_reason })).sleep);
            gpa.free((try op.wake(gpa)).call.params);
        }
        const fin = try op.feed(gpa, .{ .not_sent = ops.busy_reason });
        defer gpa.free(fin.done.result);
        try testing.expectEqual(Status.failed, fin.done.status);
        try testing.expectEqualStrings(ops.busy_reason, fin.done.result);
        // 보내지 않은 대화상자 거절은 「멈춰 있다」 가 아니다 — 스크립트가 돌지 않았다.
        var op2 = try Op.init(gpa, arg, 1);
        defer op2.deinit(gpa);
        gpa.free(try evaluated(&op2));
        const fin2 = try op2.feed(gpa, .{ .not_sent = ops.dialog_reason });
        defer gpa.free(fin2.done.result);
        try testing.expectEqualStrings(ops.dialog_reason, fin2.done.result);
    }
    {
        // 철회 — 보내기 전이면 그냥 끝, 보낸 뒤면 놓고 끝.
        var op = try Op.init(gpa, arg, 1);
        defer op.deinit(gpa);
        try testing.expect((try op.cancel(gpa)) == null);
        gpa.free(try evaluated(&op));
        op.sent = true;
        try expectRelease((try op.cancel(gpa)).?);
        const fin = try finishOp(&op);
        defer gpa.free(fin.done.result);
        try testing.expectEqualStrings("the request was cancelled", fin.done.result);
    }
}
