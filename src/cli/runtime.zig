//! Persistent session-host read/admin CLI의 순수 경계.
//! argv parsing, canonical runtime id, request payload, response DTO validation/rendering, typed
//! process exit mapping만 소유한다. Discovery/socket/process exit는 main/platform adapter가 맡는다.

const std = @import("std");
const cache_path = @import("../session/cache_path.zig");
const host_protocol = @import("../session/host_protocol.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 2,
    host_unavailable = 3,
    denied = 4,
    unsupported = 5,
    busy = 6,
    runtime_not_found = 7,
    protocol = 8,
    not_confirmed = 9,
};

pub const Output = enum { text, json };

pub const Request = union(enum) {
    host_status: Output,
    runtime_list: Output,
    runtime_get: struct {
        runtime_id: u128,
        output: Output,
    },
    runtime_end: struct {
        runtime_id: u128,
        assume_yes: bool,
    },
    /// 「누가 무엇을 선언했나」(S11-6). **사용자가 직접 부르는 명령이 아니다** — `runtime get` 이
    /// 뒤이어 한 번 더 부른다. `runtime.get` 응답 모양을 안 넓히려고 갈랐다(그쪽은 adopt 가 쓰는
    /// exact 재검증이라 소비자들이 필드 수를 정확히 센다).
    runtime_viewports: struct { runtime_id: u128 },

    pub fn output(self: Request) Output {
        return switch (self) {
            .host_status => |value| value,
            .runtime_list => |value| value,
            .runtime_get => |value| value.output,
            .runtime_end, .runtime_viewports => .text,
        };
    }

    pub fn method(self: Request) []const u8 {
        return switch (self) {
            .host_status => "host.info",
            .runtime_list => "runtime.list",
            .runtime_get => "runtime.get",
            .runtime_end => "runtime.terminate",
            .runtime_viewports => "runtime.viewports",
        };
    }
};

pub const Command = union(enum) {
    request: Request,
    help,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    MissingRuntimeId,
    InvalidRuntimeId,
    UnknownOption,
    UnexpectedArgument,
};

pub const host_help =
    \\usage: maru host status [--json]
    \\
    \\Read the current persistent session host without starting one.
    \\
;

pub const runtime_help =
    \\usage:
    \\  maru runtime list [--json]
    \\  maru runtime get <32-lower-hex-runtime-id> [--json]
    \\  maru runtime end <32-lower-hex-runtime-id> [--yes]
    \\
    \\Inspect or explicitly end persistent runtimes without starting a host.
    \\
;

pub fn parseHost(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingSubcommand;
    if (isHelp(args[0])) {
        if (args.len != 1) return error.UnexpectedArgument;
        return .help;
    }
    if (!std.mem.eql(u8, args[0], "status")) return error.UnknownSubcommand;
    return .{ .request = .{ .host_status = try parseOutput(args[1..]) } };
}

pub fn parseRuntime(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingSubcommand;
    if (isHelp(args[0])) {
        if (args.len != 1) return error.UnexpectedArgument;
        return .help;
    }
    if (std.mem.eql(u8, args[0], "list"))
        return .{ .request = .{ .runtime_list = try parseOutput(args[1..]) } };
    if (std.mem.eql(u8, args[0], "end")) return parseRuntimeEnd(args[1..]);
    if (!std.mem.eql(u8, args[0], "get")) return error.UnknownSubcommand;
    if (args.len == 1) return error.MissingRuntimeId;
    const runtime_id = parseRuntimeId(args[1]) orelse return error.InvalidRuntimeId;
    return .{ .request = .{ .runtime_get = .{
        .runtime_id = runtime_id,
        .output = try parseOutput(args[2..]),
    } } };
}

fn parseRuntimeEnd(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingRuntimeId;
    var runtime_id: ?u128 = null;
    var assume_yes = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            if (assume_yes) return error.UnexpectedArgument;
            assume_yes = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        if (runtime_id != null) return error.UnexpectedArgument;
        runtime_id = parseRuntimeId(arg) orelse return error.InvalidRuntimeId;
    }
    return .{ .request = .{ .runtime_end = .{
        .runtime_id = runtime_id orelse return error.MissingRuntimeId,
        .assume_yes = assume_yes,
    } } };
}

fn parseOutput(args: []const []const u8) ParseError!Output {
    if (args.len == 0) return .text;
    if (args.len != 1) return error.UnexpectedArgument;
    if (!std.mem.eql(u8, args[0], "--json")) return error.UnknownOption;
    return .json;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn parseRuntimeId(text: []const u8) ?u128 {
    if (text.len != 32) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    const value = std.fmt.parseInt(u128, text, 16) catch return null;
    return if (value == 0) null else value;
}

pub fn confirmationAccepted(line: []const u8) bool {
    const answer = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

pub fn paramsJson(
    allocator: std.mem.Allocator,
    request: Request,
) std.mem.Allocator.Error!?[]u8 {
    return switch (request) {
        .host_status, .runtime_list => null,
        .runtime_get => |value| try runtimeIdParams(allocator, value.runtime_id),
        .runtime_end => |value| try runtimeIdParams(allocator, value.runtime_id),
        .runtime_viewports => |value| try runtimeIdParams(allocator, value.runtime_id),
    };
}

fn runtimeIdParams(allocator: std.mem.Allocator, runtime_id: u128) std.mem.Allocator.Error![]u8 {
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{x:0>32}", .{runtime_id}) catch unreachable;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(.{ .runtime_id = &id }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

pub const RemoteError = host_protocol.ErrorCode;

pub fn remoteExitCode(code: RemoteError) ExitCode {
    return switch (code) {
        .host_unavailable, .stale_host, .host_shutting_down => .host_unavailable,
        .unauthorized => .denied,
        .incompatible_version, .upgrade_unsupported => .unsupported,
        .controller_busy, .upgrade_busy, .resource_exhausted => .busy,
        .runtime_not_found => .runtime_not_found,
        else => .protocol,
    };
}

pub const ExpectedHost = struct {
    host_id: u128,
    build_id: []const u8,
    protocol_major: u16,
    screen_codec_version: u16,
    upgrade_epoch: u64,
    authority_generation: u64,
    lifecycle: []const u8,
};

pub const HostStatus = struct {
    host_id: [32]u8,
    build_id: []u8,
    protocol_major: u16,
    screen_codec_version: u16,
    upgrade_epoch: u64,
    authority_generation: u64,
    lifecycle: []u8,
    runtime_count: usize,
    client_count: usize,

    pub fn deinit(self: *HostStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.build_id);
        allocator.free(self.lifecycle);
        self.* = undefined;
    }
};

pub const RuntimeMeta = struct {
    runtime_id: [32]u8,
    cols: u16,
    rows: u16,
    resize_generation: u64,
    has_controller: bool,
    observer_count: usize,
    /// window title(§8). **자기 자리에 복사해 든다** — `Result.deinit` 은 목록 배열만 풀고
    /// `runtime_get` 갈래는 아무것도 안 풀어서, 소유 포인터를 들면 그쪽에서 샌다.
    /// 상한을 넘으면 UTF-8 경계에서 자른다(host 도 같은 상한으로 자르지만, 그 값을 믿지 않는다).
    title: [host_protocol.max_title_bytes]u8 = @splat(0),
    title_len: usize = 0,
    /// observer 들이 알린 격자(S11-6). **`runtime get` 에만 실린다** — 세션이 왜 작아졌는지
    /// 짚으려면 「누가 무엇을 선언했나」가 있어야 한다. 상한을 넘는 것은 버리고 개수만 센다.
    declared: [max_declared_viewports]DeclaredViewport = undefined,
    declared_len: usize = 0,
    /// 실제로 선언한 observer 수. `declared_len` 보다 클 수 있다(상한을 넘은 만큼).
    declared_total: usize = 0,

    pub fn titleText(self: *const RuntimeMeta) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn declaredViewports(self: *const RuntimeMeta) []const DeclaredViewport {
        return self.declared[0..self.declared_len];
    }
};

/// 한 줄에 적어 보일 만한 수. 넘으면 개수로만 알린다.
pub const max_declared_viewports: usize = 8;

pub const DeclaredViewport = struct {
    stream_id: u64,
    cols: u16,
    rows: u16,
};

/// 상한 안으로 자르되 UTF-8 경계를 지킨다 — 바이트로 자르면 깨진 시퀀스를 화면에 그린다.
fn clampTitleBytes(text: []const u8) []const u8 {
    if (text.len <= host_protocol.max_title_bytes) return text;
    var end = host_protocol.max_title_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub const Result = union(enum) {
    host_status: HostStatus,
    runtime_list: []RuntimeMeta,
    runtime_get: RuntimeMeta,
    runtime_end: [32]u8,
    runtime_viewports: DeclaredViewports,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .host_status => |*value| value.deinit(allocator),
            .runtime_list => |items| allocator.free(items),
            .runtime_get => {},
            .runtime_end => {},
            .runtime_viewports => {},
        }
        self.* = undefined;
    }
};

/// 한 runtime 의 선언들. 상한을 넘는 것은 `total` 로만 센다.
pub const DeclaredViewports = struct {
    items: [max_declared_viewports]DeclaredViewport = undefined,
    len: usize = 0,
    total: usize = 0,

    pub fn view(self: *const DeclaredViewports) []const DeclaredViewport {
        return self.items[0..self.len];
    }
};

pub const DecodeError = error{ OutOfMemory, Malformed, Remote };

pub fn decodeResponse(
    allocator: std.mem.Allocator,
    request: Request,
    payload: []const u8,
    expected_host: ?ExpectedHost,
    remote_error: *?RemoteError,
) DecodeError!Result {
    remote_error.* = null;
    var envelope = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    defer envelope.deinit();
    const object = switch (envelope.value) {
        .object => |value| value,
        else => return error.Malformed,
    };
    const error_value = object.get("error");
    const result_value = object.get("result");
    if ((error_value == null) == (result_value == null)) return error.Malformed;
    if (error_value) |value| {
        const name = switch (value) {
            .string => |text| text,
            else => return error.Malformed,
        };
        remote_error.* = parseRemoteError(name) orelse return error.Malformed;
        return error.Remote;
    }
    return switch (request) {
        .host_status => .{ .host_status = try decodeHostStatus(
            allocator,
            envelope.value,
            expected_host orelse return error.Malformed,
        ) },
        .runtime_list => .{ .runtime_list = try decodeRuntimeList(allocator, envelope.value) },
        .runtime_get => |get| .{ .runtime_get = try decodeRuntimeGet(
            allocator,
            envelope.value,
            get.runtime_id,
        ) },
        .runtime_viewports => .{ .runtime_viewports = try decodeViewports(allocator, envelope.value) },
        .runtime_end => |end| .{ .runtime_end = try decodeRuntimeEnd(
            allocator,
            envelope.value,
            end.runtime_id,
        ) },
    };
}

fn decodeRuntimeEnd(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected_runtime_id: u128,
) DecodeError![32]u8 {
    const Wire = struct { result: struct { terminated: bool } };
    var parsed = std.json.parseFromValue(Wire, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    defer parsed.deinit();
    if (!parsed.value.result.terminated) return error.Malformed;
    var id_buf: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&id_buf, "{x:0>32}", .{expected_runtime_id}) catch unreachable;
    return id_buf;
}

fn parseRemoteError(name: []const u8) ?RemoteError {
    inline for (std.meta.fields(RemoteError)) |field|
        if (std.mem.eql(u8, name, field.name))
            return @enumFromInt(field.value);
    return null;
}

fn decodeHostStatus(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected: ExpectedHost,
) DecodeError!HostStatus {
    const Wire = struct {
        result: struct {
            host_id: []const u8,
            build_id: []const u8,
            protocol_major: u16,
            screen_codec_version: u16,
            upgrade_epoch: u64,
            authority_generation: u64,
            lifecycle: []const u8,
            runtime_count: usize,
            client_count: usize,
        },
    };
    var parsed = std.json.parseFromValue(Wire, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    defer parsed.deinit();
    const id = copyCanonicalId(parsed.value.result.host_id) orelse return error.Malformed;
    const expected_id = std.fmt.parseInt(u128, &id, 16) catch return error.Malformed;
    if (expected_id != expected.host_id or
        !std.mem.eql(u8, parsed.value.result.build_id, expected.build_id) or
        parsed.value.result.protocol_major != expected.protocol_major or
        parsed.value.result.screen_codec_version != expected.screen_codec_version or
        parsed.value.result.upgrade_epoch != expected.upgrade_epoch or
        parsed.value.result.authority_generation != expected.authority_generation or
        !std.mem.eql(u8, parsed.value.result.lifecycle, expected.lifecycle))
        return error.Malformed;
    const build_id = allocator.dupe(u8, parsed.value.result.build_id) catch return error.OutOfMemory;
    errdefer allocator.free(build_id);
    const lifecycle = allocator.dupe(u8, parsed.value.result.lifecycle) catch return error.OutOfMemory;
    if (lifecycle.len == 0) {
        allocator.free(lifecycle);
        return error.Malformed;
    }
    return .{
        .host_id = id,
        .build_id = build_id,
        .protocol_major = parsed.value.result.protocol_major,
        .screen_codec_version = parsed.value.result.screen_codec_version,
        .upgrade_epoch = parsed.value.result.upgrade_epoch,
        .authority_generation = parsed.value.result.authority_generation,
        .lifecycle = lifecycle,
        .runtime_count = parsed.value.result.runtime_count,
        .client_count = parsed.value.result.client_count,
    };
}

fn decodeRuntimeList(allocator: std.mem.Allocator, value: std.json.Value) DecodeError![]RuntimeMeta {
    const WireMeta = struct {
        runtime_id: []const u8,
        cols: u16,
        rows: u16,
        resize_generation: u64,
        has_controller: bool,
        observer_count: usize,
        /// 구 host 는 안 싣는다 — optional 이라 없어도 파싱된다(§8).
        title: ?[]const u8 = null,
    };
    const Wire = struct { result: struct { runtimes: []WireMeta } };
    var parsed = std.json.parseFromValue(Wire, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    defer parsed.deinit();
    if (!validRuntimeCount(parsed.value.result.runtimes.len)) return error.Malformed;
    const items = allocator.alloc(RuntimeMeta, parsed.value.result.runtimes.len) catch
        return error.OutOfMemory;
    errdefer allocator.free(items);
    for (parsed.value.result.runtimes, items) |wire, *item|
        item.* = decodeRuntimeMeta(wire) orelse return error.Malformed;
    std.mem.sort(RuntimeMeta, items, {}, struct {
        fn lessThan(_: void, a: RuntimeMeta, b: RuntimeMeta) bool {
            return std.mem.order(u8, &a.runtime_id, &b.runtime_id) == .lt;
        }
    }.lessThan);
    if (items.len > 1)
        for (items[1..], items[0 .. items.len - 1]) |current, previous|
            if (std.mem.eql(u8, &current.runtime_id, &previous.runtime_id))
                return error.Malformed;
    return items;
}

fn validRuntimeCount(count: usize) bool {
    return count <= host_protocol.max_inventory_runtimes;
}

fn decodeRuntimeGet(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected_runtime_id: u128,
) DecodeError!RuntimeMeta {
    const Wire = struct {
        result: struct {
            runtime_id: []const u8,
            cols: u16,
            rows: u16,
            resize_generation: u64,
            has_controller: bool,
            observer_count: usize,
            /// 구 host 는 안 싣는다 — optional 이라 없어도 파싱된다(§8).
            title: ?[]const u8 = null,
        },
    };
    var parsed = std.json.parseFromValue(Wire, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    defer parsed.deinit();
    const result = decodeRuntimeMeta(parsed.value.result) orelse return error.Malformed;
    const actual = std.fmt.parseInt(u128, &result.runtime_id, 16) catch return error.Malformed;
    if (actual != expected_runtime_id) return error.Malformed;
    return result;
}

fn decodeViewports(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) DecodeError!DeclaredViewports {
    const Wire = struct {
        result: struct { declared: []const DeclaredViewport },
    };
    var parsed = std.json.parseFromValue(Wire, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    defer parsed.deinit();
    const list = parsed.value.result.declared;
    var out: DeclaredViewports = .{ .total = list.len };
    out.len = @min(list.len, max_declared_viewports);
    @memcpy(out.items[0..out.len], list[0..out.len]);
    return out;
}

fn decodeRuntimeMeta(wire: anytype) ?RuntimeMeta {
    var meta: RuntimeMeta = .{
        .runtime_id = copyCanonicalId(wire.runtime_id) orelse return null,
        .cols = wire.cols,
        .rows = wire.rows,
        .resize_generation = wire.resize_generation,
        .has_controller = wire.has_controller,
        .observer_count = wire.observer_count,
    };
    // **없어도 정상이다**(§8 — optional). 구 host 는 이 필드를 아예 안 싣는다.
    if (wire.title) |raw| {
        const text = clampTitleBytes(raw);
        @memcpy(meta.title[0..text.len], text);
        meta.title_len = text.len;
    }
    return meta;
}

fn copyCanonicalId(text: []const u8) ?[32]u8 {
    _ = parseRuntimeId(text) orelse return null;
    var result: [32]u8 = undefined;
    @memcpy(&result, text);
    return result;
}

pub fn render(result: Result, output: Output, writer: *std.Io.Writer) !void {
    if (output == .json) return renderJson(result, writer);
    switch (result) {
        .host_status => |value| {
            try writer.print(
                "Host {s}\nBuild: {s}\nProtocol: {d} (screen {d})\nLifecycle: {s}\nRuntimes: {d}\nClients: {d}\n",
                .{
                    &value.host_id,
                    value.build_id,
                    value.protocol_major,
                    value.screen_codec_version,
                    value.lifecycle,
                    value.runtime_count,
                    value.client_count,
                },
            );
        },
        .runtime_list => |items| {
            if (items.len == 0) return writer.writeAll("No persistent runtimes.\n");
            for (items) |item| try renderRuntimeLine(item, writer);
        },
        .runtime_get => |item| {
            try renderRuntimeLine(item, writer);
            try renderDeclaredViewports(item, writer);
        },
        .runtime_end => |runtime_id| try writer.print("Ended runtime {s}.\n", .{&runtime_id}),
        // **혼자서는 안 그린다.** 이 결과는 `runtime get` 이 자기 줄 아래에 붙여 내는 재료다 —
        // 따로 그리면 같은 정보가 두 모양으로 갈린다.
        .runtime_viewports => {},
    }
}

fn renderRuntimeLine(item: RuntimeMeta, writer: *std.Io.Writer) !void {
    try writer.print(
        "{s}  {d}x{d}  controller={s}  observers={d}  resize-generation={d}",
        .{
            &item.runtime_id,
            item.cols,
            item.rows,
            if (item.has_controller) "yes" else "no",
            item.observer_count,
            item.resize_generation,
        },
    );
    // **없으면 자리도 안 만든다** — 빈 `title=` 을 적으면 "제목이 빈 세션" 으로 읽힌다.
    if (item.title_len > 0) try writer.print("  title={s}", .{item.titleText()});
    try writer.writeAll("\n");
}

/// 「누가 무엇을 선언했나」. **선언이 없으면 한 줄도 안 낸다** — 이 기능을 안 쓰는 세션의 출력이
/// 예전과 같아야 한다.
fn renderDeclaredViewports(item: RuntimeMeta, writer: *std.Io.Writer) !void {
    if (item.declared_total == 0) return;
    for (item.declaredViewports()) |view|
        try writer.print(
            "  declared stream={d} {d}x{d}\n",
            .{ view.stream_id, view.cols, view.rows },
        );
    // **감춘 것을 감추지 않는다.** 상한에서 잘렸으면 몇이 안 보이는지 적는다.
    if (item.declared_total > item.declared_len)
        try writer.print(
            "  declared +{d} more\n",
            .{item.declared_total - item.declared_len},
        );
}

fn renderJson(result: Result, writer: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    switch (result) {
        .host_status => |value| try json.write(.{
            .host_id = &value.host_id,
            .build_id = value.build_id,
            .protocol_major = value.protocol_major,
            .screen_codec_version = value.screen_codec_version,
            .upgrade_epoch = value.upgrade_epoch,
            .authority_generation = value.authority_generation,
            .lifecycle = value.lifecycle,
            .runtime_count = value.runtime_count,
            .client_count = value.client_count,
        }),
        .runtime_list => |items| {
            try writer.writeAll("{\"runtimes\":[");
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeRuntimeJson(item, writer);
            }
            try writer.writeAll("]}");
        },
        .runtime_get => |item| try writeRuntimeJson(item, writer),
        .runtime_end, .runtime_viewports => return error.JsonOutputUnsupported,
    }
    try writer.writeByte('\n');
}

fn writeRuntimeJson(item: RuntimeMeta, writer: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginObject();
    try json.objectField("runtime_id");
    try json.write(&item.runtime_id);
    try json.objectField("cols");
    try json.write(item.cols);
    try json.objectField("rows");
    try json.write(item.rows);
    try json.objectField("resize_generation");
    try json.write(item.resize_generation);
    try json.objectField("has_controller");
    try json.write(item.has_controller);
    try json.objectField("observer_count");
    try json.write(item.observer_count);
    // **없으면 키도 안 낸다** — `"title":""` 은 "제목이 빈 세션" 이라는 다른 말이고, 소비자가
    // 그것을 값으로 읽는다(폰 목록이 빈 줄을 그린다). 선언도 같은 규칙이다.
    if (item.title_len > 0) {
        try json.objectField("title");
        try json.write(item.titleText());
    }
    // **텍스트만 보여 주면 관측 구멍이다** — 스크립트가 `--json` 으로 「왜 작아졌나」를 못 읽는다.
    if (item.declared_total > 0) {
        try json.objectField("declared");
        try json.beginArray();
        for (item.declaredViewports()) |view| {
            try json.beginObject();
            try json.objectField("stream_id");
            try json.write(view.stream_id);
            try json.objectField("cols");
            try json.write(view.cols);
            try json.objectField("rows");
            try json.write(view.rows);
            try json.endObject();
        }
        try json.endArray();
        // **감춘 것을 감추지 않는다** — 상한에서 잘렸으면 몇인지 기계도 알아야 한다.
        if (item.declared_total > item.declared_len) {
            try json.objectField("declared_total");
            try json.write(item.declared_total);
        }
    }
    try json.endObject();
}

test "runtime CLI parser exposes only implemented read commands and canonical IDs" {
    try std.testing.expect((try parseHost(&.{"--help"})) == .help);
    try std.testing.expect((try parseHost(&.{"status"})).request == .host_status);
    try std.testing.expectEqual(Output.json, (try parseHost(&.{ "status", "--json" })).request.output());
    try std.testing.expect((try parseRuntime(&.{"list"})).request == .runtime_list);
    const get = (try parseRuntime(&.{ "get", "0000000000000000000000000000aabb", "--json" })).request.runtime_get;
    try std.testing.expectEqual(@as(u128, 0xAABB), get.runtime_id);
    try std.testing.expectEqual(Output.json, get.output);
    try std.testing.expectError(error.InvalidRuntimeId, parseRuntime(&.{ "get", "aabb" }));
    try std.testing.expectError(error.InvalidRuntimeId, parseRuntime(&.{ "get", "0000000000000000000000000000AABB" }));
    const end = (try parseRuntime(&.{ "end", "--yes", "0000000000000000000000000000aabb" })).request.runtime_end;
    try std.testing.expectEqual(@as(u128, 0xAABB), end.runtime_id);
    try std.testing.expect(end.assume_yes);
    try std.testing.expectError(error.MissingRuntimeId, parseRuntime(&.{"end"}));
    try std.testing.expectError(error.UnexpectedArgument, parseRuntime(&.{ "end", "0000000000000000000000000000aabb", "--yes", "--yes" }));
    try std.testing.expect(confirmationAccepted("yes\n"));
    try std.testing.expect(confirmationAccepted(" Y "));
    try std.testing.expect(!confirmationAccepted("no\n"));
}

test "runtime CLI decodes, sorts, and renders stable text and JSON DTOs" {
    const payload =
        \\{"result":{"runtimes":[{"runtime_id":"000000000000000000000000000000bb","cols":132,"rows":43,"resize_generation":2,"has_controller":false,"observer_count":1},{"runtime_id":"000000000000000000000000000000aa","cols":80,"rows":24,"resize_generation":1,"has_controller":true,"observer_count":0}]}}
    ;
    var remote: ?RemoteError = null;
    var result = try decodeResponse(
        std.testing.allocator,
        .{ .runtime_list = .json },
        payload,
        null,
        &remote,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(remote == null);
    try std.testing.expectEqualStrings("000000000000000000000000000000aa", &result.runtime_list[0].runtime_id);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(result, .json, &out.writer);
    try std.testing.expectEqualStrings(
        "{\"runtimes\":[{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":80,\"rows\":24,\"resize_generation\":1,\"has_controller\":true,\"observer_count\":0},{\"runtime_id\":\"000000000000000000000000000000bb\",\"cols\":132,\"rows\":43,\"resize_generation\":2,\"has_controller\":false,\"observer_count\":1}]}\n",
        out.written(),
    );
}

test "title 은 있을 때만 실리고, 없는 응답도 그대로 읽힌다" {
    // **구 host 는 이 필드를 아예 안 싣는다**(§8 optional). 그때 목록이 통째로 안 읽히면
    // 새 CLI 가 옛 host 를 못 보게 된다 — wire major 를 안 올린 이유가 이것이다.
    const payload =
        \\{"result":{"runtimes":[{"runtime_id":"000000000000000000000000000000aa","cols":80,"rows":24,"resize_generation":1,"has_controller":true,"observer_count":0,"title":"zsh — maru"},{"runtime_id":"000000000000000000000000000000bb","cols":132,"rows":43,"resize_generation":2,"has_controller":false,"observer_count":1}]}}
    ;
    var remote: ?RemoteError = null;
    var result = try decodeResponse(std.testing.allocator, .{ .runtime_list = .json }, payload, null, &remote);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zsh — maru", result.runtime_list[0].titleText());
    // 없는 쪽은 **빈 문자열이 아니라 길이 0** 이고, 그래서 화면에도 JSON 에도 자리를 안 만든다.
    try std.testing.expectEqual(@as(usize, 0), result.runtime_list[1].title_len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(result, .json, &out.writer);
    // 있는 쪽만 키가 있다 — 빈 `"title":""` 를 실으면 소비자가 "제목이 빈 세션" 으로 읽는다.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"title\":\"zsh — maru\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"title\":\"\"") == null);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try render(result, .text, &text.writer);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "title=zsh — maru") != null);
    // 제목 없는 줄에는 `title=` 자체가 없다.
    var lines = std.mem.splitScalar(u8, text.written(), '\n');
    _ = lines.next();
    const second = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, second, "title=") == null);
}

test "긴 title 은 UTF-8 경계에서 잘린다 — 깨진 시퀀스를 그리지 않는다" {
    // host 도 같은 상한으로 자르지만 **그 값을 믿지 않는다** — wire 는 원격이 만든 것이다.
    // 바이트로 자르면 마지막 글자가 반쪽이 되어 화면에 깨진 글자가 뜬다.
    const one = "한"; // 3바이트
    var long: [host_protocol.max_title_bytes + 12]u8 = undefined;
    var i: usize = 0;
    while (i + one.len <= long.len) : (i += one.len) @memcpy(long[i..][0..one.len], one);
    const clamped = clampTitleBytes(long[0..i]);
    try std.testing.expect(clamped.len <= host_protocol.max_title_bytes);
    try std.testing.expectEqual(@as(usize, 0), clamped.len % one.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clamped));
    // 상한 이하는 그대로 둔다.
    try std.testing.expectEqualStrings("zsh", clampTitleBytes("zsh"));
}

test "runtime CLI renders exact host get and empty-list text snapshots" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(.{ .host_status = .{
        .host_id = "000000000000000000000000000000aa".*,
        .build_id = @constCast("sha256:test"),
        .protocol_major = 2,
        .screen_codec_version = 1,
        .upgrade_epoch = 4,
        .authority_generation = 7,
        .lifecycle = @constCast("ready"),
        .runtime_count = 3,
        .client_count = 2,
    } }, .text, &out.writer);
    try std.testing.expectEqualStrings(
        "Host 000000000000000000000000000000aa\nBuild: sha256:test\nProtocol: 2 (screen 1)\nLifecycle: ready\nRuntimes: 3\nClients: 2\n",
        out.written(),
    );
    out.clearRetainingCapacity();
    try render(.{ .runtime_get = .{
        .runtime_id = "000000000000000000000000000000bb".*,
        .cols = 132,
        .rows = 43,
        .resize_generation = 9,
        .has_controller = true,
        .observer_count = 4,
    } }, .text, &out.writer);
    try std.testing.expectEqualStrings(
        "000000000000000000000000000000bb  132x43  controller=yes  observers=4  resize-generation=9\n",
        out.written(),
    );
    out.clearRetainingCapacity();
    try render(.{ .runtime_list = &.{} }, .text, &out.writer);
    try std.testing.expectEqualStrings("No persistent runtimes.\n", out.written());
}

test "runtime end decodes only explicit success and renders the requested canonical id" {
    const request: Request = .{ .runtime_end = .{
        .runtime_id = 0xaa,
        .assume_yes = true,
    } };
    const params = (try paramsJson(std.testing.allocator, request)).?;
    defer std.testing.allocator.free(params);
    try std.testing.expectEqualStrings(
        "{\"runtime_id\":\"000000000000000000000000000000aa\"}",
        params,
    );
    var remote: ?RemoteError = null;
    var result = try decodeResponse(
        std.testing.allocator,
        request,
        "{\"result\":{\"terminated\":true}}",
        null,
        &remote,
    );
    defer result.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(result, .text, &out.writer);
    try std.testing.expectEqualStrings(
        "Ended runtime 000000000000000000000000000000aa.\n",
        out.written(),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            request,
            "{\"result\":{\"terminated\":false}}",
            null,
            &remote,
        ),
    );
}

test "runtime CLI maps typed remote errors to stable exits" {
    const expected = [_]ExitCode{
        .host_unavailable, // host_unavailable
        .protocol, // invalid_request
        .unsupported, // incompatible_version
        .denied, // unauthorized
        .runtime_not_found,
        .host_unavailable, // stale_host
        .busy, // controller_busy
        .protocol, // invalid_generation
        .protocol, // payload_too_large
        .protocol, // queue_invalidated
        .host_unavailable, // host_shutting_down
        .busy, // upgrade_busy
        .protocol, // attempt_conflict
        .unsupported, // upgrade_unsupported
        .protocol, // invalid_target
        .busy, // resource_exhausted
        .protocol, // internal
    };
    inline for (std.meta.fields(RemoteError)) |field| {
        const code: RemoteError = @enumFromInt(field.value);
        try std.testing.expectEqual(expected[field.value], remoteExitCode(code));
    }
}

test "runtime CLI rejects conflicting envelopes and response identity drift" {
    var remote: ?RemoteError = null;
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            .{ .runtime_list = .json },
            "{\"error\":123,\"result\":{\"runtimes\":[]}}",
            null,
            &remote,
        ),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            .{ .runtime_list = .json },
            "{\"error\":\"internal\",\"result\":{\"runtimes\":[]}}",
            null,
            &remote,
        ),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            .{ .runtime_get = .{ .runtime_id = 0xaa, .output = .json } },
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000bb\",\"cols\":80,\"rows\":24,\"resize_generation\":1,\"has_controller\":false,\"observer_count\":0}}",
            null,
            &remote,
        ),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            .{ .runtime_list = .json },
            "{\"result\":{\"runtimes\":[{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":80,\"rows\":24,\"resize_generation\":1,\"has_controller\":false,\"observer_count\":0},{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":80,\"rows\":24,\"resize_generation\":1,\"has_controller\":false,\"observer_count\":0}]}}",
            null,
            &remote,
        ),
    );

    const host_payload =
        "{\"result\":{\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:wrong\",\"protocol_major\":2,\"screen_codec_version\":1,\"upgrade_epoch\":4,\"authority_generation\":1,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}";
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            .{ .host_status = .json },
            host_payload,
            .{
                .host_id = 0xaa,
                .build_id = "sha256:expected",
                .protocol_major = 2,
                .screen_codec_version = 1,
                .upgrade_epoch = 4,
                .authority_generation = 1,
                .lifecycle = "ready",
            },
            &remote,
        ),
    );
    const identity_mismatches = [_][]const u8{
        "{\"result\":{\"host_id\":\"000000000000000000000000000000bb\",\"build_id\":\"sha256:expected\",\"protocol_major\":2,\"screen_codec_version\":1,\"upgrade_epoch\":4,\"authority_generation\":1,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}",
        "{\"result\":{\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:expected\",\"protocol_major\":3,\"screen_codec_version\":1,\"upgrade_epoch\":4,\"authority_generation\":1,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}",
        "{\"result\":{\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:expected\",\"protocol_major\":2,\"screen_codec_version\":2,\"upgrade_epoch\":4,\"authority_generation\":1,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}",
        "{\"result\":{\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:expected\",\"protocol_major\":2,\"screen_codec_version\":1,\"upgrade_epoch\":5,\"authority_generation\":1,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}",
        "{\"result\":{\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:expected\",\"protocol_major\":2,\"screen_codec_version\":1,\"upgrade_epoch\":4,\"authority_generation\":2,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}",
        "{\"result\":{\"host_id\":\"000000000000000000000000000000aa\",\"build_id\":\"sha256:expected\",\"protocol_major\":2,\"screen_codec_version\":1,\"upgrade_epoch\":4,\"authority_generation\":1,\"lifecycle\":\"draining\",\"runtime_count\":0,\"client_count\":1}}",
    };
    for (identity_mismatches) |payload|
        try std.testing.expectError(
            error.Malformed,
            decodeResponse(
                std.testing.allocator,
                .{ .host_status = .json },
                payload,
                .{
                    .host_id = 0xaa,
                    .build_id = "sha256:expected",
                    .protocol_major = 2,
                    .screen_codec_version = 1,
                    .upgrade_epoch = 4,
                    .authority_generation = 1,
                    .lifecycle = "ready",
                },
                &remote,
            ),
        );
}

test "runtime CLI response inventory bound is the shared protocol limit" {
    try std.testing.expect(validRuntimeCount(host_protocol.max_inventory_runtimes));
    try std.testing.expect(!validRuntimeCount(host_protocol.max_inventory_runtimes + 1));

    var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"result\":{\"runtimes\":[");
    for (0..host_protocol.max_inventory_runtimes + 1) |index| {
        if (index != 0) try payload.writer.writeByte(',');
        try payload.writer.print(
            "{{\"runtime_id\":\"{x:0>32}\",\"cols\":80,\"rows\":24,\"resize_generation\":0,\"has_controller\":false,\"observer_count\":0}}",
            .{index + 1},
        );
    }
    try payload.writer.writeAll("]}}");
    var remote: ?RemoteError = null;
    try std.testing.expectError(
        error.Malformed,
        decodeResponse(
            std.testing.allocator,
            .{ .runtime_list = .json },
            payload.written(),
            null,
            &remote,
        ),
    );
}

test "S11-6 runtime get 이 누가 무엇을 선언했는지 보인다" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var meta: RuntimeMeta = .{
        .runtime_id = "000000000000000000000000000000bb".*,
        .cols = 80,
        .rows = 24,
        .resize_generation = 3,
        .has_controller = true,
        .observer_count = 2,
    };
    meta.declared[0] = .{ .stream_id = 7, .cols = 50, .rows = 37 };
    meta.declared_len = 1;
    meta.declared_total = 1;
    try render(.{ .runtime_get = meta }, .text, &out.writer);
    try std.testing.expectEqualStrings(
        "000000000000000000000000000000bb  80x24  controller=yes  observers=2  resize-generation=3\n" ++
            "  declared stream=7 50x37\n",
        out.written(),
    );
}

test "S11-6 선언이 없으면 출력이 예전과 같다 — 그리고 잘린 것은 감추지 않는다" {
    const T = std.testing;
    {
        var out: std.Io.Writer.Allocating = .init(T.allocator);
        defer out.deinit();
        const meta: RuntimeMeta = .{
            .runtime_id = "000000000000000000000000000000bb".*,
            .cols = 80,
            .rows = 24,
            .resize_generation = 0,
            .has_controller = false,
            .observer_count = 0,
        };
        try render(.{ .runtime_get = meta }, .text, &out.writer);
        // **이 기능을 안 쓰는 세션은 한 줄도 늘지 않는다.**
        try T.expectEqualStrings(
            "000000000000000000000000000000bb  80x24  controller=no  observers=0  resize-generation=0\n",
            out.written(),
        );
    }
    {
        var out: std.Io.Writer.Allocating = .init(T.allocator);
        defer out.deinit();
        var meta: RuntimeMeta = .{
            .runtime_id = "000000000000000000000000000000bb".*,
            .cols = 80,
            .rows = 24,
            .resize_generation = 0,
            .has_controller = false,
            .observer_count = 20,
        };
        for (0..max_declared_viewports) |i|
            meta.declared[i] = .{ .stream_id = i + 1, .cols = 50, .rows = 37 };
        meta.declared_len = max_declared_viewports;
        meta.declared_total = 11;
        try render(.{ .runtime_get = meta }, .text, &out.writer);
        // **감춘 것을 감추지 않는다** — 상한에서 잘렸으면 몇이 안 보이는지 적는다.
        try T.expect(std.mem.endsWith(u8, out.written(), "  declared +3 more\n"));
    }
}

test "S11-6 --json 도 선언을 싣는다 — 텍스트만 보여 주면 스크립트가 못 읽는다" {
    const T = std.testing;
    {
        var out: std.Io.Writer.Allocating = .init(T.allocator);
        defer out.deinit();
        var meta: RuntimeMeta = .{
            .runtime_id = "000000000000000000000000000000bb".*,
            .cols = 80,
            .rows = 24,
            .resize_generation = 3,
            .has_controller = true,
            .observer_count = 2,
        };
        meta.declared[0] = .{ .stream_id = 7, .cols = 50, .rows = 37 };
        meta.declared_len = 1;
        meta.declared_total = 1;
        try render(.{ .runtime_get = meta }, .json, &out.writer);
        try T.expectEqualStrings(
            "{\"runtime_id\":\"000000000000000000000000000000bb\",\"cols\":80,\"rows\":24," ++
                "\"resize_generation\":3,\"has_controller\":true,\"observer_count\":2," ++
                "\"declared\":[{\"stream_id\":7,\"cols\":50,\"rows\":37}]}\n",
            out.written(),
        );
    }
    {
        // 선언이 없으면 **키도 안 낸다** — 이 기능을 안 쓰는 세션의 JSON 은 예전과 같아야 한다.
        var out: std.Io.Writer.Allocating = .init(T.allocator);
        defer out.deinit();
        const meta: RuntimeMeta = .{
            .runtime_id = "000000000000000000000000000000bb".*,
            .cols = 80,
            .rows = 24,
            .resize_generation = 0,
            .has_controller = false,
            .observer_count = 0,
        };
        try render(.{ .runtime_get = meta }, .json, &out.writer);
        try T.expectEqualStrings(
            "{\"runtime_id\":\"000000000000000000000000000000bb\",\"cols\":80,\"rows\":24," ++
                "\"resize_generation\":0,\"has_controller\":false,\"observer_count\":0}\n",
            out.written(),
        );
    }
    {
        // 잘렸으면 기계도 알아야 한다.
        var out: std.Io.Writer.Allocating = .init(T.allocator);
        defer out.deinit();
        var meta: RuntimeMeta = .{
            .runtime_id = "000000000000000000000000000000bb".*,
            .cols = 80,
            .rows = 24,
            .resize_generation = 0,
            .has_controller = false,
            .observer_count = 20,
        };
        for (0..max_declared_viewports) |i|
            meta.declared[i] = .{ .stream_id = i + 1, .cols = 50, .rows = 37 };
        meta.declared_len = max_declared_viewports;
        meta.declared_total = 11;
        try render(.{ .runtime_get = meta }, .json, &out.writer);
        try T.expect(std.mem.endsWith(u8, out.written(), ",\"declared_total\":11}\n"));
    }
}
