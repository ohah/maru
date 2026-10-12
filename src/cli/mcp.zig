//! `maru mcp` 의 **순수 절반**(W9f) — MCP(Model Context Protocol) stdio 서버가 받는 JSON-RPC 한 줄을 풀고, 도구 표를 내고,
//! 도구 인자를 `maru browser` CLI 인자로 옮긴다. 소켓·표준 입출력은 짝인 [`mcp/run.zig`](mcp/run.zig)가 한다(`browser.zig` ↔
//! `browser/run.zig` 와 같은 분할 — 순수 규칙은 `tests/boundary/cli_purity.zig`).
//!
//! **도구는 CLI 하위 명령 그대로다.** 인자를 CLI 인자로 옮겨 `browser.parse` 가 검사하게 한다 — 검사 규칙(로케이터 배타·상한·
//! 시한 범위)이 CLI 한 곳에만 있다. 도구 결과는 CLI 가 낼 글 그대로(사람과 에이전트가 같은 글을 본다), 실패면 `isError`.
//! 원격 디버깅 포트를 열지 않는다 — 요청은 같은 컨트롤 소켓으로 간다(pane 신원 1g 가 이 프로세스의 조상 사슬로 pane 을 찾는다).
const std = @import("std");
const cp = @import("../session/control_plane.zig");

/// 우리가 아는 MCP 판(새 것부터). 클라이언트가 청한 판이 이 안에 있으면 그것으로, 아니면 첫 것으로 답한다(스펙의 협상).
pub const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };
pub const server_name = "maru";

/// 도구 인자 하나가 CLI 에서 어떤 모양인가.
pub const ArgKind = enum {
    /// `--flag <문자열>`
    string,
    /// `--flag <정수>`(0 이상)
    int,
    /// 참이면 `--flag`(거짓이면 없음)
    flag,
    /// 위치 인자(문자열) — 맨 뒤에
    positional,
    /// JSON 배열을 글로 펴서 `--flag <json>`
    json_array,
    /// 수(소수 가능) — `--flag <수>`
    number,
};

pub const Arg = struct {
    key: []const u8,
    kind: ArgKind,
    /// CLI 의 옵션 이름(`positional` 이면 빈 글).
    flag: []const u8 = "",
    description: []const u8,
    required: bool = false,
};

pub const Tool = struct {
    name: []const u8,
    /// `maru browser` 하위 명령.
    subcommand: []const u8,
    description: []const u8,
    args: []const Arg,
};

const surface: Arg = .{ .key = "surface", .kind = .int, .flag = "--surface", .description = "tab id from browser_list or browser_open", .required = true };
const locator_args = [_]Arg{
    .{ .key = "selector", .kind = .string, .flag = "--selector", .description = "CSS selector" },
    .{ .key = "ref", .kind = .string, .flag = "--ref", .description = "element ref from browser_snapshot (like n123)" },
    .{ .key = "role", .kind = .string, .flag = "--role", .description = "ARIA role (Chromium tabs), with name/level" },
    .{ .key = "name", .kind = .string, .flag = "--name", .description = "accessible name for role" },
    .{ .key = "level", .kind = .int, .flag = "--level", .description = "heading level for role=heading" },
    .{ .key = "by_text", .kind = .string, .flag = "--by-text", .description = "visible text (Chromium tabs)" },
    .{ .key = "by_label", .kind = .string, .flag = "--by-label", .description = "form label text (Chromium tabs)" },
    .{ .key = "exact", .kind = .flag, .flag = "--exact", .description = "match the name/text exactly" },
    .{ .key = "nth", .kind = .int, .flag = "--nth", .description = "pick the nth match (0-based)" },
};

fn withSurface(comptime extra: []const Arg) []const Arg {
    return &([_]Arg{surface} ++ extra[0..extra.len].*);
}

pub const tools = [_]Tool{
    .{ .name = "browser_list", .subcommand = "list", .description = "List the browser tabs of this maru instance (id, url, title, engine, controllable methods).", .args = &.{} },
    .{ .name = "browser_open", .subcommand = "open", .description = "Open a Chromium tab behind the current one in this pane and wait for its first load. Returns the new tab id. Only from a maru pane; up to 8 tabs per pane.", .args = &.{
        .{ .key = "url", .kind = .string, .flag = "--url", .description = "http(s) address to load (omit for a blank tab)" },
        .{ .key = "timeout_ms", .kind = .int, .flag = "--timeout", .description = "how long to wait for the first load (1-25000, default 25000)" },
    } },
    .{ .name = "browser_close", .subcommand = "close", .description = "Close a tab this pane opened (asks the page; a page that asks before leaving is not closed).", .args = withSurface(&.{}) },
    .{ .name = "browser_navigate", .subcommand = "navigate", .description = "Navigate a tab to an address.", .args = withSurface(&.{.{ .key = "url", .kind = .positional, .description = "address", .required = true }}) },
    .{ .name = "browser_get_url", .subcommand = "get-url", .description = "Print the tab's current document address.", .args = withSurface(&.{}) },
    .{ .name = "browser_click", .subcommand = "click", .description = "Click an element with real mouse input (Chromium tabs). Give one locator: selector, ref, role (+name/level), by_text or by_label.", .args = withSurface(&locator_args) },
    .{ .name = "browser_type", .subcommand = "type", .description = "Type text into an element (replaces its text; real input on Chromium tabs).", .args = withSurface(&(locator_args ++ [_]Arg{.{ .key = "text", .kind = .string, .flag = "--text", .description = "text to type", .required = true }})) },
    .{ .name = "browser_scroll", .subcommand = "scroll", .description = "Scroll an element into view.", .args = withSurface(&locator_args) },
    .{ .name = "browser_hover", .subcommand = "hover", .description = "Move the pointer onto an element (real input; Chromium tabs).", .args = withSurface(&locator_args) },
    .{ .name = "browser_press", .subcommand = "press", .description = "Press a key like Enter, Shift+Tab or Meta+a (on the element, or where the focus is; Chromium tabs).", .args = withSurface(&([_]Arg{.{ .key = "key", .kind = .string, .flag = "--key", .description = "key spec", .required = true }} ++ locator_args)) },
    .{ .name = "browser_wait", .subcommand = "wait", .description = "Wait for a selector, the page load, or a locator to be visible (default and max 25000 ms).", .args = withSurface(&(locator_args ++ [_]Arg{
        .{ .key = "load", .kind = .flag, .flag = "--load", .description = "wait until the page is loaded" },
        .{ .key = "visible", .kind = .flag, .flag = "--visible", .description = "with a locator: wait until it is visible" },
        .{ .key = "timeout_ms", .kind = .int, .flag = "--timeout", .description = "1-25000" },
    })) },
    .{ .name = "browser_snapshot", .subcommand = "snapshot", .description = "Print the page accessibility tree with refs for later actions. On big pages pass interactive, max_depth or selector to keep the result small.", .args = withSurface(&.{
        .{ .key = "interactive", .kind = .flag, .flag = "--interactive", .description = "only interactive elements" },
        .{ .key = "max_depth", .kind = .int, .flag = "--max-depth", .description = "tree depth limit" },
        .{ .key = "selector", .kind = .string, .flag = "--selector", .description = "only under this element" },
    }) },
    .{ .name = "browser_console", .subcommand = "console", .description = "Print page console logs.", .args = withSurface(&.{.{ .key = "clear", .kind = .flag, .flag = "--clear", .description = "empty the log after reading" }}) },
    .{ .name = "browser_back", .subcommand = "back", .description = "Go back in the tab's history (Chromium tabs).", .args = withSurface(&.{}) },
    .{ .name = "browser_forward", .subcommand = "forward", .description = "Go forward in the tab's history (Chromium tabs).", .args = withSurface(&.{}) },
    .{ .name = "browser_reload", .subcommand = "reload", .description = "Reload the page (Chromium tabs).", .args = withSurface(&.{}) },
    .{ .name = "browser_exec", .subcommand = "exec", .description = "Run and await a JavaScript expression in the page; prints its result.", .args = withSurface(&.{
        .{ .key = "expression", .kind = .positional, .description = "JavaScript expression", .required = true },
        .{ .key = "args", .kind = .json_array, .flag = "--args", .description = "JSON array of arguments" },
        .{ .key = "max_result_bytes", .kind = .int, .flag = "--max-result-bytes", .description = "result size limit" },
    }) },
    .{ .name = "browser_screenshot", .subcommand = "screenshot", .description = "Capture the tab as a PNG image (the whole page at device scale, or a region).", .args = withSurface(&.{
        .{ .key = "rect", .kind = .string, .flag = "--rect", .description = "region x,y,w,h in CSS pixels" },
        .{ .key = "scale", .kind = .number, .flag = "--scale", .description = "scale factor (for example 0.5 for a smaller image)" },
    }) },
};

/// 결과를 그림으로 돌려주는 도구(CLI 가 표준 출력에 PNG 바이트를 쓴다).
pub fn returnsImage(tool: *const Tool) bool {
    return std.mem.eql(u8, tool.subcommand, "screenshot");
}

pub fn findTool(name: []const u8) ?*const Tool {
    for (&tools) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

pub const ArgError = error{ UnknownArgument, WrongType, MissingArgument, OutOfMemory };

/// 도구 인자(JSON 객체)를 `maru browser` CLI 인자로 옮긴다 — 하위 명령이 맨 앞, 위치 인자는 맨 뒤. 모르는 키·틀린 형은 거절한다
/// (CLI 가 모르는 옵션을 거절하는 것과 같다 — 오타가 조용히 무시되지 않게). 값의 범위·배타는 `browser.parse` 가 본다. 돌려준 글은
/// `arena` 소유.
pub fn argv(arena: std.mem.Allocator, tool: *const Tool, arguments: ?std.json.Value) ArgError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, tool.subcommand);
    var positional: ?[]const u8 = null;
    const obj: ?std.json.ObjectMap = if (arguments) |a| switch (a) {
        .object => |o| o,
        .null => null,
        else => return error.WrongType,
    } else null;
    if (obj) |o| {
        var it = o.iterator();
        while (it.next()) |e| {
            const spec = for (tool.args) |*a| {
                if (std.mem.eql(u8, a.key, e.key_ptr.*)) break a;
            } else return error.UnknownArgument;
            const v = e.value_ptr.*;
            switch (spec.kind) {
                // 값은 `--flag=값` 한 토큰으로 — 값이 `-` 로 시작하거나 `--help` 여도 옵션·도움말로 읽히지 않는다.
                .string => switch (v) {
                    .string => |s| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ spec.flag, s })),
                    else => return error.WrongType,
                },
                .int => switch (v) {
                    .integer => |n| {
                        if (n < 0) return error.WrongType;
                        try out.append(arena, try std.fmt.allocPrint(arena, "{s}={d}", .{ spec.flag, n }));
                    },
                    else => return error.WrongType,
                },
                .number => switch (v) {
                    .integer => |n| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={d}", .{ spec.flag, n })),
                    .float => |f| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={d}", .{ spec.flag, f })),
                    else => return error.WrongType,
                },
                .flag => switch (v) {
                    .bool => |b| if (b) try out.append(arena, spec.flag),
                    else => return error.WrongType,
                },
                .positional => switch (v) {
                    .string => |s| positional = s,
                    else => return error.WrongType,
                },
                .json_array => switch (v) {
                    .array => {
                        var aw: std.Io.Writer.Allocating = .init(arena);
                        std.json.Stringify.value(v, .{}, &aw.writer) catch return error.OutOfMemory;
                        try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ spec.flag, aw.written() }));
                    },
                    else => return error.WrongType,
                },
            }
        }
    }
    for (tool.args) |a| if (a.required) {
        const present = if (obj) |o| o.contains(a.key) else false;
        if (!present) return error.MissingArgument;
    };
    // 위치 인자는 `--` 뒤에 — `-` 로 시작해도(`-1`·`-h`) 옵션·도움말로 읽히지 않는다.
    if (positional) |p| try out.appendSlice(arena, &.{ "--", p });
    return out.toOwnedSlice(arena);
}

/// 받은 한 줄이 무엇인가.
pub const Incoming = union(enum) {
    /// 곧 돌려줄 응답(소유 — 부른 쪽이 놓는다).
    reply: []u8,
    /// 도구를 부른다 — 부른 쪽이 CLI 를 돌리고 `toolResult` 로 답한다. `id`·`argv` 는 `arena` 소유.
    call: struct { id: cp.Id, tool: *const Tool, argv: []const []const u8 },
    /// 답하지 않는다(알림·응답).
    none,
};

/// JSON-RPC 한 줄을 처리한다. `arena` 는 이 줄의 수명(부른 쪽이 줄마다 비운다), 응답 글은 `gpa` 소유.
pub fn handleLine(gpa: std.mem.Allocator, arena: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!Incoming {
    const pm = cp.parseMessage(arena, line) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .reply = try cp.serializeError(gpa, .null, cp.parseFailureCode(e), "invalid JSON-RPC message", null) },
    };
    const req = switch (pm.message) {
        .request => |r| r,
        .notification, .response => return .none, // notifications/initialized·cancelled 등 — 답하지 않는다
    };
    const id = try dupeId(arena, req.id);
    if (std.mem.eql(u8, req.method, "initialize")) return .{ .reply = try initializeResult(gpa, id, req.params) };
    if (std.mem.eql(u8, req.method, "ping")) return .{ .reply = try emptyResult(gpa, id) };
    if (std.mem.eql(u8, req.method, "tools/list")) return .{ .reply = try toolsListResult(gpa, id) };
    if (std.mem.eql(u8, req.method, "tools/call")) {
        const params = if (req.params) |p| switch (p) {
            .object => |o| o,
            else => return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tools/call params must be an object", null) },
        } else return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tools/call needs params", null) };
        const name = if (params.get("name")) |n| switch (n) {
            .string => |s| s,
            else => return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tool name must be a string", null) },
        } else return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "tool name is missing", null) };
        const tool = findTool(name) orelse return .{ .reply = try cp.serializeError(gpa, id, .invalid_params, "unknown tool", null) };
        const args = argv(arena, tool, params.get("arguments")) catch |e| return .{ .reply = try toolResult(gpa, id, switch (e) {
            error.UnknownArgument => "error: unknown argument for this tool (see its input schema)",
            error.WrongType => "error: an argument has the wrong type (see the tool's input schema)",
            error.MissingArgument => "error: a required argument is missing",
            error.OutOfMemory => return error.OutOfMemory,
        }, true) };
        return .{ .call = .{ .id = id, .tool = tool, .argv = args } };
    }
    return .{ .reply = try cp.serializeError(gpa, id, .method_not_found, "method not found", null) };
}

fn dupeId(arena: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error!cp.Id {
    return switch (id) {
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        else => id,
    };
}

fn beginResult(s: *std.json.Stringify, id: cp.Id) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    switch (id) {
        .null => try s.write(null),
        .number => |n| try s.write(n),
        .string => |str| try s.write(str),
    }
    try s.objectField("result");
}

fn emptyResult(gpa: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn initializeResult(gpa: std.mem.Allocator, id: cp.Id, params: ?std.json.Value) std.mem.Allocator.Error![]u8 {
    var version: []const u8 = protocol_versions[0];
    if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
        for (protocol_versions) |known| if (std.mem.eql(u8, known, v.string)) {
            version = known;
        };
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("protocolVersion") catch |e| break :blk e;
        s.write(version) catch |e| break :blk e;
        s.objectField("capabilities") catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("tools") catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.objectField("serverInfo") catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("name") catch |e| break :blk e;
        s.write(server_name) catch |e| break :blk e;
        s.objectField("version") catch |e| break :blk e;
        s.write("0") catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.objectField("instructions") catch |e| break :blk e;
        s.write("Control the browser tabs of the maru terminal this agent runs in. Find tabs with browser_list or open one with browser_open, " ++
            "then act on them by id (surface). Prefer locators (role/by_text/by_label) or refs from browser_snapshot over CSS selectors. " ++
            "Requests come from the maru pane this process runs in; controlling a tab you did not open asks the user once. " ++
            "While the user answers that confirmation a call can take up to about 150 seconds (2 minutes for the answer, then the action), " ++
            "so give this server a tool timeout of at least 150 seconds. Calls run one at a time.") catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSchema(s: *std.json.Stringify, tool: *const Tool) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    for (tool.args) |a| {
        try s.objectField(a.key);
        try s.beginObject();
        try s.objectField("type");
        try s.write(switch (a.kind) {
            .string, .positional => "string",
            .int => "integer",
            .number => "number",
            .flag => "boolean",
            .json_array => "array",
        });
        if (a.kind == .int) {
            try s.objectField("minimum");
            try s.write(0);
        }
        try s.objectField("description");
        try s.write(a.description);
        try s.endObject();
    }
    try s.endObject();
    try s.objectField("required");
    try s.beginArray();
    for (tool.args) |a| if (a.required) try s.write(a.key);
    try s.endArray();
    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();
}

fn toolsListResult(gpa: std.mem.Allocator, id: cp.Id) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("tools") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        for (&tools) |*t| {
            s.beginObject() catch |e| break :blk e;
            s.objectField("name") catch |e| break :blk e;
            s.write(t.name) catch |e| break :blk e;
            s.objectField("description") catch |e| break :blk e;
            s.write(t.description) catch |e| break :blk e;
            s.objectField("inputSchema") catch |e| break :blk e;
            writeSchema(&s, t) catch |e| break :blk e;
            s.endObject() catch |e| break :blk e;
        }
        s.endArray() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// 도구 결과 — CLI 가 낸 글 그대로(`text`), 실패면 `isError`.
/// 그림 도구 결과 — `content:[{type:"image", data:<base64>, mimeType:"image/png"}]`.
pub fn imageResult(gpa: std.mem.Allocator, id: cp.Id, png: []const u8) std.mem.Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const data = try gpa.alloc(u8, enc.calcSize(png.len));
    defer gpa.free(data);
    _ = enc.encode(data, png);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("content") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("type") catch |e| break :blk e;
        s.write("image") catch |e| break :blk e;
        s.objectField("data") catch |e| break :blk e;
        s.write(data) catch |e| break :blk e;
        s.objectField("mimeType") catch |e| break :blk e;
        s.write("image/png") catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endArray() catch |e| break :blk e;
        s.objectField("isError") catch |e| break :blk e;
        s.write(false) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn toolResult(gpa: std.mem.Allocator, id: cp.Id, text: []const u8, is_error: bool) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    (blk: {
        beginResult(&s, id) catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("content") catch |e| break :blk e;
        s.beginArray() catch |e| break :blk e;
        s.beginObject() catch |e| break :blk e;
        s.objectField("type") catch |e| break :blk e;
        s.write("text") catch |e| break :blk e;
        s.objectField("text") catch |e| break :blk e;
        s.write(text) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endArray() catch |e| break :blk e;
        s.objectField("isError") catch |e| break :blk e;
        s.write(is_error) catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
        s.endObject() catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const browser = @import("browser.zig");

test "W9f: 도구 인자는 CLI 인자로 — 로케이터·플래그·위치 인자, 모르는 키·틀린 형·빠진 필수는 거절" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parse = struct {
        fn f(a: std.mem.Allocator, json: []const u8) !std.json.Value {
            return (try std.json.parseFromSlice(std.json.Value, a, json, .{})).value;
        }
    }.f;
    const click = findTool("browser_click").?;
    const a = try argv(arena, click, try parse(arena, "{\"surface\":7,\"role\":\"button\",\"name\":\"Save\",\"exact\":true,\"nth\":1}"));
    // 인자 순서는 JSON 객체 순서 — browser.parse 가 받는지가 중요하다.
    const p = try browser.parse(a);
    try testing.expectEqual(@as(u64, 7), p.request.click.surface_id);
    try testing.expectEqualStrings("click", a[0]);
    const nav = findTool("browser_navigate").?;
    const n = try argv(arena, nav, try parse(arena, "{\"url\":\"https://e.test/\",\"surface\":3}"));
    try testing.expectEqualStrings("https://e.test/", n[n.len - 1]); // 위치 인자는 맨 뒤(`--` 뒤)
    try testing.expectEqualStrings("--", n[n.len - 2]);
    try testing.expectEqualStrings("https://e.test/", (try browser.parse(n)).request.navigate.url);
    const open = findTool("browser_open").?;
    try testing.expectEqualStrings("open", (try argv(arena, open, null))[0]);
    try testing.expectError(error.UnknownArgument, argv(arena, click, try parse(arena, "{\"surface\":7,\"selectr\":\"#a\"}")));
    try testing.expectError(error.WrongType, argv(arena, click, try parse(arena, "{\"surface\":\"7\"}")));
    try testing.expectError(error.WrongType, argv(arena, click, try parse(arena, "{\"surface\":-1}")));
    try testing.expectError(error.MissingArgument, argv(arena, click, try parse(arena, "{\"selector\":\"#a\"}")));
    try testing.expectError(error.WrongType, argv(arena, click, try parse(arena, "[1]")));
    const exec = findTool("browser_exec").?;
    const e = try argv(arena, exec, try parse(arena, "{\"surface\":2,\"expression\":\"1+1\",\"args\":[1,\"x\"]}"));
    const at = for (e, 0..) |tok, i| {
        if (std.mem.startsWith(u8, tok, "--args=")) break i;
    } else return error.TestUnexpectedResult;
    try testing.expectEqualStrings("--args=[1,\"x\"]", e[at]);
    try testing.expectEqualStrings("1+1", e[e.len - 1]);
}

test "W9f: 도구 표의 모든 도구는 CLI 하위 명령이고, 필수 인자만 준 호출을 browser.parse 가 받는다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (&tools) |*t| {
        var obj: std.json.ObjectMap = .empty;
        for (t.args) |a| if (a.required) try obj.put(arena, a.key, switch (a.kind) {
            .int => .{ .integer = 4 },
            .string, .positional => .{ .string = if (std.mem.eql(u8, a.key, "key")) "Enter" else if (std.mem.eql(u8, a.key, "url")) "https://e.test/" else "x" },
            else => .{ .bool = true },
        });
        const extra: ?[]const u8 = if (std.mem.eql(u8, t.subcommand, "click") or std.mem.eql(u8, t.subcommand, "type") or std.mem.eql(u8, t.subcommand, "scroll") or std.mem.eql(u8, t.subcommand, "hover"))
            "selector"
        else if (std.mem.eql(u8, t.subcommand, "wait")) "selector" else null;
        if (extra) |k| try obj.put(arena, k, .{ .string = "#a" });
        const a = try argv(arena, t, .{ .object = obj });
        _ = browser.parse(a) catch |err| {
            std.debug.print("tool {s} → {any}\n", .{ t.name, err });
            return err;
        };
    }
}

test "W9f: JSON-RPC — initialize 는 아는 판으로, tools/list·ping·모르는 메서드·알림, tools/call 은 CLI 인자로" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "\"protocolVersion\":\"2025-03-26\"") != null);
        try testing.expect(std.mem.indexOf(u8, r, "\"tools\":{}") != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "\"id\":\"a\"") != null);
        try testing.expect(std.mem.indexOf(u8, r, protocol_versions[0]) != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")).reply;
        defer testing.allocator.free(r);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
        defer parsed.deinit();
        try testing.expectEqual(tools.len, parsed.value.object.get("result").?.object.get("tools").?.array.items.len);
    }
    try testing.expect(try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == .none);
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "-32601") != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "not json")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "-32700") != null);
    }
    {
        const c = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_close\",\"arguments\":{\"surface\":12}}}")).call;
        try testing.expectEqualStrings("close", c.argv[0]);
        try testing.expectEqual(@as(i64, 4), c.id.number);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_close\",\"arguments\":{\"id\":12}}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "\"isError\":true") != null);
    }
    {
        const r = (try handleLine(testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}")).reply;
        defer testing.allocator.free(r);
        try testing.expect(std.mem.indexOf(u8, r, "-32602") != null);
    }
}

test "W9f: 도구 결과는 MCP content 한 글과 isError" {
    const r = try toolResult(testing.allocator, .{ .number = 9 }, "opened 7 https://e.test/\n", false);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"opened 7 https://e.test/\\n\"}],\"isError\":false}}", r);
}

test "W9f: 스크린샷은 그림 결과(base64 PNG), rect·scale 은 CLI 인자로" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shot = findTool("browser_screenshot").?;
    try testing.expect(returnsImage(shot));
    try testing.expect(!returnsImage(findTool("browser_snapshot").?));
    const v = (try std.json.parseFromSlice(std.json.Value, arena, "{\"surface\":3,\"rect\":\"0,0,10,10\",\"scale\":0.5}", .{})).value;
    const p = try browser.parse(try argv(arena, shot, v));
    try testing.expectEqual(@as(u64, 3), p.screenshot.surface_id);
    const r = try imageResult(testing.allocator, .{ .number = 9 }, "\x89PNG");
    defer testing.allocator.free(r);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r, .{});
    defer parsed.deinit();
    const c = parsed.value.object.get("result").?.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("image", c.get("type").?.string);
    try testing.expectEqualStrings("iVBORw==", c.get("data").?.string);
    try testing.expectEqualStrings("image/png", c.get("mimeType").?.string);
}

test "W9f: `-` 로 시작하는 exec 식도 식으로 간다(옵션으로 읽히지 않는다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exec = findTool("browser_exec").?;
    for ([_][]const u8{ "-1", "--x", "-document.body.scrollHeight" }) |expr| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "surface", .{ .integer = 2 });
        try obj.put(arena, "expression", .{ .string = expr });
        const p = try browser.parse(try argv(arena, exec, .{ .object = obj }));
        try testing.expectEqualStrings(expr, std.mem.trimStart(u8, p.request.exec.script, " "));
    }
}

test "W9f: `-` 로 시작하거나 `--help` 인 값도 값으로 간다(도움말·옵션으로 읽히지 않는다)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { tool: []const u8, key: []const u8, value: []const u8 };
    for ([_]Case{
        .{ .tool = "browser_type", .key = "text", .value = "--help" },
        .{ .tool = "browser_type", .key = "text", .value = "-h" },
        .{ .tool = "browser_type", .key = "text", .value = "-5" },
        .{ .tool = "browser_press", .key = "key", .value = "-" },
        .{ .tool = "browser_click", .key = "by_text", .value = "-" },
        .{ .tool = "browser_exec", .key = "expression", .value = "-h" },
    }) |c| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "surface", .{ .integer = 2 });
        try obj.put(arena, c.key, .{ .string = c.value });
        if (std.mem.eql(u8, c.tool, "browser_type")) try obj.put(arena, "selector", .{ .string = "#a" });
        const cmd = browser.parse(try argv(arena, findTool(c.tool).?, .{ .object = obj })) catch |e| {
            std.debug.print("{s} {s}={s} → {any}\n", .{ c.tool, c.key, c.value, e });
            return e;
        };
        if (cmd != .request) {
            std.debug.print("{s} {s}={s} → {s}\n", .{ c.tool, c.key, c.value, @tagName(cmd) });
            return error.TestUnexpectedResult;
        }
    }
}
