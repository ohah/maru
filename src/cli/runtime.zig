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

    pub fn output(self: Request) Output {
        return switch (self) {
            .host_status => |value| value,
            .runtime_list => |value| value,
            .runtime_get => |value| value.output,
            .runtime_end => .text,
        };
    }

    pub fn method(self: Request) []const u8 {
        return switch (self) {
            .host_status => "host.info",
            .runtime_list => "runtime.list",
            .runtime_get => "runtime.get",
            .runtime_end => "runtime.terminate",
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
};

pub const Result = union(enum) {
    host_status: HostStatus,
    runtime_list: []RuntimeMeta,
    runtime_get: RuntimeMeta,
    runtime_end: [32]u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .host_status => |*value| value.deinit(allocator),
            .runtime_list => |items| allocator.free(items),
            .runtime_get => {},
            .runtime_end => {},
        }
        self.* = undefined;
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

fn decodeRuntimeMeta(wire: anytype) ?RuntimeMeta {
    return .{
        .runtime_id = copyCanonicalId(wire.runtime_id) orelse return null,
        .cols = wire.cols,
        .rows = wire.rows,
        .resize_generation = wire.resize_generation,
        .has_controller = wire.has_controller,
        .observer_count = wire.observer_count,
    };
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
        .runtime_get => |item| try renderRuntimeLine(item, writer),
        .runtime_end => |runtime_id| try writer.print("Ended runtime {s}.\n", .{&runtime_id}),
    }
}

fn renderRuntimeLine(item: RuntimeMeta, writer: *std.Io.Writer) !void {
    try writer.print(
        "{s}  {d}x{d}  controller={s}  observers={d}  resize-generation={d}\n",
        .{
            &item.runtime_id,
            item.cols,
            item.rows,
            if (item.has_controller) "yes" else "no",
            item.observer_count,
            item.resize_generation,
        },
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
        .runtime_end => return error.JsonOutputUnsupported,
    }
    try writer.writeByte('\n');
}

fn writeRuntimeJson(item: RuntimeMeta, writer: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.write(.{
        .runtime_id = &item.runtime_id,
        .cols = item.cols,
        .rows = item.rows,
        .resize_generation = item.resize_generation,
        .has_controller = item.has_controller,
        .observer_count = item.observer_count,
    });
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
