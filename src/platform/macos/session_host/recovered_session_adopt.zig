//! CR6b Recovered Sessions one-item adopt의 fresh authority preflight.
//!
//! Sidebar projection은 발견 시점의 파생 snapshot일 뿐 attach 권위가 아니다. 사용자 action은 현재 app-local
//! generation을 먼저 대조하고, 같은 canonical adapter에서 새 `host.info`와 `runtime.get`을 왕복한 결과를 이
//! 모듈로 검증한 뒤에만 topology/attach stage로 넘어간다. 이 파일은 UI나 Term을 소유하지 않는다.

const std = @import("std");
const projection_mod = @import("recovered_sessions_projection.zig");

/// Sidebar action 하나가 fresh host.info + runtime.get 전체에 공유하는 non-resettable budget.
pub const action_deadline_ns: i128 = 5 * std.time.ns_per_s;

pub const CurrentAuthority = struct {
    projection_generation: u64,
    workspace_generation: u64,
    adapter_generation: u64,
    adapter_host_id: u128,
};

pub const Error = error{
    InvalidAuthority,
    MalformedResponse,
    RuntimeNotFound,
    OutOfMemory,
};

/// Fresh wire evidence를 projection snapshot과 exact 비교한다. `runtime.get`의 error response도 정상적인
/// stale-action 결과이므로 별도 `RuntimeNotFound`로 돌려 caller가 attach/spawn/terminate mutation 0으로 끝내게 한다.
pub fn validateFreshEvidence(
    allocator: std.mem.Allocator,
    row: projection_mod.Row,
    current: CurrentAuthority,
    host_info_bytes: []const u8,
    runtime_get_bytes: []const u8,
) Error!void {
    if (row.projection_generation == 0 or
        row.projection_generation != current.projection_generation or
        row.authority.workspace_generation != current.workspace_generation or
        row.authority.adapter_generation != current.adapter_generation or
        row.host_id != current.adapter_host_id or
        row.authority.host_id != row.host_id or
        row.runtime_id == 0)
        return error.InvalidAuthority;

    const HostResponse = struct {
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
    var host = std.json.parseFromSlice(HostResponse, allocator, host_info_bytes, .{}) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedResponse;
    defer host.deinit();
    const host_id = parseExactHex128(host.value.result.host_id) orelse return error.MalformedResponse;
    if (host_id != row.host_id or
        host.value.result.upgrade_epoch != row.authority.upgrade_epoch or
        host.value.result.authority_generation != row.authority.authority_generation or
        !std.mem.eql(u8, host.value.result.lifecycle, "ready"))
        return error.InvalidAuthority;

    var runtime_value = std.json.parseFromSlice(std.json.Value, allocator, runtime_get_bytes, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedResponse;
    defer runtime_value.deinit();
    if (runtime_value.value != .object or runtime_value.value.object.count() != 1)
        return error.MalformedResponse;
    const root = runtime_value.value.object;
    if (root.get("error")) |value| {
        if (value == .string and std.mem.eql(u8, value.string, "runtime_not_found"))
            return error.RuntimeNotFound;
        return error.MalformedResponse;
    }
    const result_value = root.get("result") orelse return error.MalformedResponse;
    if (result_value != .object or result_value.object.count() != 6) return error.MalformedResponse;
    const result = result_value.object;
    const runtime_id_value = result.get("runtime_id") orelse return error.MalformedResponse;
    if (runtime_id_value != .string) return error.MalformedResponse;
    const runtime_id = parseExactHex128(runtime_id_value.string) orelse return error.MalformedResponse;
    if (runtime_id != row.runtime_id) return error.InvalidAuthority;
    const cols = jsonU64(result.get("cols") orelse return error.MalformedResponse) orelse
        return error.MalformedResponse;
    const rows = jsonU64(result.get("rows") orelse return error.MalformedResponse) orelse
        return error.MalformedResponse;
    _ = jsonU64(result.get("resize_generation") orelse return error.MalformedResponse) orelse
        return error.MalformedResponse;
    const has_controller = result.get("has_controller") orelse return error.MalformedResponse;
    if (has_controller != .bool) return error.MalformedResponse;
    _ = jsonU64(result.get("observer_count") orelse return error.MalformedResponse) orelse
        return error.MalformedResponse;
    if (cols == 0 or cols > std.math.maxInt(u16) or rows == 0 or rows > std.math.maxInt(u16))
        return error.MalformedResponse;
}

fn parseExactHex128(text: []const u8) ?u128 {
    if (text.len != 32) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return null;
    const value = std.fmt.parseInt(u128, text, 16) catch return null;
    return if (value == 0) null else value;
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| std.math.cast(u64, number),
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn testRow() projection_mod.Row {
    return .{
        .kind = .orphan,
        .host_id = 1,
        .runtime_id = 2,
        .manifest_index = null,
        .authority = .{
            .host_id = 1,
            .adapter_generation = 3,
            .upgrade_epoch = 4,
            .authority_generation = 5,
            .membership_generation = 6,
            .workspace_generation = 7,
        },
        .projection_generation = 8,
        .label = "00000002".*,
    };
}

const host_ok =
    \\{"result":{"host_id":"00000000000000000000000000000001","build_id":"sha256:test","protocol_major":2,"screen_codec_version":2,"upgrade_epoch":4,"authority_generation":5,"lifecycle":"ready","runtime_count":1,"client_count":1}}
;
const runtime_ok =
    \\{"result":{"runtime_id":"00000000000000000000000000000002","cols":80,"rows":24,"resize_generation":0,"has_controller":false,"observer_count":0}}
;

test "CR6b recovered adopt fresh evidence는 projection host runtime 권위를 exact 재검증한다" {
    try validateFreshEvidence(std.testing.allocator, testRow(), .{
        .projection_generation = 8,
        .workspace_generation = 7,
        .adapter_generation = 3,
        .adapter_host_id = 1,
    }, host_ok, runtime_ok);
}

test "CR6b recovered adopt stale authority와 사라진 runtime은 topology mutation 전에 거부한다" {
    const current: CurrentAuthority = .{
        .projection_generation = 8,
        .workspace_generation = 7,
        .adapter_generation = 3,
        .adapter_host_id = 1,
    };
    inline for (@typeInfo(CurrentAuthority).@"struct".fields) |field| {
        var drift = current;
        @field(drift, field.name) +%= 1;
        try std.testing.expectError(
            error.InvalidAuthority,
            validateFreshEvidence(std.testing.allocator, testRow(), drift, host_ok, runtime_ok),
        );
    }
    const host_drift =
        \\{"result":{"host_id":"00000000000000000000000000000001","build_id":"sha256:test","protocol_major":2,"screen_codec_version":2,"upgrade_epoch":4,"authority_generation":6,"lifecycle":"ready","runtime_count":1,"client_count":1}}
    ;
    try std.testing.expectError(
        error.InvalidAuthority,
        validateFreshEvidence(std.testing.allocator, testRow(), current, host_drift, runtime_ok),
    );
    try std.testing.expectError(
        error.RuntimeNotFound,
        validateFreshEvidence(std.testing.allocator, testRow(), current, host_ok, "{\"error\":\"runtime_not_found\"}"),
    );
}

test "CR6b recovered adopt malformed fresh response는 permissive fallback 없이 닫힌다" {
    const current: CurrentAuthority = .{
        .projection_generation = 8,
        .workspace_generation = 7,
        .adapter_generation = 3,
        .adapter_host_id = 1,
    };
    inline for ([_][]const u8{
        "{}",
        "{\"result\":{}}",
        "{\"result\":{\"runtime_id\":\"00000000000000000000000000000002\"}}",
        "{\"result\":{\"runtime_id\":\"0000000000000000000000000000000A\",\"cols\":80,\"rows\":24,\"resize_generation\":0,\"has_controller\":false,\"observer_count\":0}}",
    }) |bad_runtime| try std.testing.expectError(
        error.MalformedResponse,
        validateFreshEvidence(std.testing.allocator, testRow(), current, host_ok, bad_runtime),
    );
}
