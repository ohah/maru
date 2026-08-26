//! `maru incidents` 서브커맨드의 **순수 CLI 로직** — 인자 파싱, `--help` 텍스트, 레코드 포맷.
//!
//! **왜 있나**: `ConnectionIncident`는 쓰기만 되고 읽히지 않았다. 2026-08-26에 앱이 host 연결을 잃은 원인을
//! 찾을 때 `.incident`를 손으로 hexdump해야 했고, 그 해독은 스키마 표를 사람이 옮겨 적은 것이라 틀려도 아무도
//! 못 잡는다. 이 CLI는 **디스크만 읽는다** — 살아 있는 인스턴스가 없어도, `maru sessions list`가
//! "multiple maru instances"로 거부하는 상태에서도 답한다. 진단이 가장 필요한 순간이 정확히 그때다.
//!
//! I/O(디렉토리 열거·파일 읽기·digest 검증)는 호출자가 갖고, 여기엔 파싱·포맷 같은 테스트 가능한 로직만 둔다
//! (cli/sessions.zig·ssh.zig와 같은 패턴 — docs/project-structure.md `src/cli/`).

const std = @import("std");
const incident = @import("../observability/connection_incident.zig");

pub const default_limit: usize = 20;

pub const help =
    \\usage: maru incidents list [--json] [--limit <n>]
    \\
    \\read connection incident artifacts left by this and earlier app instances.
    \\reads on-disk records only, so it still answers when no instance is running.
    \\
    \\options:
    \\  --json        emit one JSON object per record
    \\  --limit <n>   show at most <n> most recent records (default 20)
    \\
;

pub const List = struct {
    json: bool = false,
    limit: usize = default_limit,
};

pub const Parsed = union(enum) { list: List, help };

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    UnknownOption,
    MissingValue,
    InvalidLimit,
};

/// `args`는 `incidents` **뒤**의 토큰만 받는다(main이 서브커맨드 이름을 이미 소비한 뒤).
pub fn parse(args: []const []const u8) ParseError!Parsed {
    if (args.len == 0) return error.MissingSubcommand;
    if (isHelpFlag(args[0])) return .help;
    if (!std.mem.eql(u8, args[0], "list")) return error.UnknownSubcommand;

    var result: List = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelpFlag(arg)) return .help;
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            result.limit = std.fmt.parseInt(usize, args[index], 10) catch return error.InvalidLimit;
            if (result.limit == 0) return error.InvalidLimit;
        } else return error.UnknownOption;
    }
    return .{ .list = result };
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// raw를 닫힌 enum 이름으로 옮긴다. `decodeIncident`가 이미 범위를 검증했지만, 이름 붙이기가 검증을 **다시**
/// 하도록 두어 표에 정체불명의 숫자가 사실처럼 찍히지 않게 한다.
fn tagName(comptime E: type, raw: u8) []const u8 {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (field.value == raw) return field.name;
    }
    return "?";
}

pub fn writeHeader(writer: *std.Io.Writer) !void {
    try writer.writeAll("seq  reason                        site                  disposition  parser   outbound  host_id                           conn  wire  pending(req/stm/ev)\n");
}

pub fn writeIncident(writer: *std.Io.Writer, value: incident.ConnectionIncident) !void {
    try writer.print("{d:<4} {s:<29} {s:<21} {s:<12} {s:<8} {s:<9} {x:0>32}  {d:<5} {d:<5} {d}/{d}/{d}\n", .{
        value.incident_id.sequence,
        tagName(incident.ConnectionReason, value.reason_raw),
        tagName(incident.SourceSite, value.source_site_raw),
        tagName(incident.Disposition, value.disposition_raw),
        tagName(incident.ParserPhase, value.parser_phase_raw),
        tagName(incident.OutboundPhase, value.outbound_phase_raw),
        value.host_id,
        value.connection_generation,
        value.wire_major,
        value.pending_request_count,
        value.pending_stream_count,
        value.pending_event_count,
    });
}

pub fn writeIncidentJson(writer: *std.Io.Writer, value: incident.ConnectionIncident) !void {
    try writer.print(
        \\{{"record":"incident","app_instance_nonce":"{x:0>32}","sequence":{d},"timestamp_ns":{d},"reason":"{s}","scope":"{s}","disposition":"{s}","source_site":"{s}","host_class":"{s}","parser_phase":"{s}","outbound_phase":"{s}","expected":{s},"transport_usable":{s},"host_id":"{x:0>32}","host_adapter_generation":{d},"connection_generation":{d},"wire_major":{d},"last_success_request_id":{d},"pending_request_count":{d},"pending_stream_count":{d},"pending_event_count":{d},"queue_item_count":{d},"queue_bytes":{d},"outbound_offset":{d},"outbound_length":{d},"controller_generation":{d},"upgrade_epoch":{d}}}
        \\
    , .{
        value.incident_id.app_instance_nonce,
        value.incident_id.sequence,
        value.timestamp_ns,
        tagName(incident.ConnectionReason, value.reason_raw),
        tagName(incident.Scope, value.scope_raw),
        tagName(incident.Disposition, value.disposition_raw),
        tagName(incident.SourceSite, value.source_site_raw),
        tagName(incident.HostClass, value.host_class_raw),
        tagName(incident.ParserPhase, value.parser_phase_raw),
        tagName(incident.OutboundPhase, value.outbound_phase_raw),
        if (value.flags & 0x01 != 0) "true" else "false",
        if (value.flags & 0x02 != 0) "true" else "false",
        value.host_id,
        value.host_adapter_generation,
        value.connection_generation,
        value.wire_major,
        value.last_success_request_id,
        value.pending_request_count,
        value.pending_stream_count,
        value.pending_event_count,
        value.queue_item_count,
        value.queue_bytes,
        value.outbound_offset,
        value.outbound_length,
        value.controller_generation,
        value.upgrade_epoch,
    });
}

pub fn writeAggregateJson(writer: *std.Io.Writer, value: incident.IncidentAggregate) !void {
    try writer.print(
        \\{{"record":"aggregate","reason":"{s}","source_site":"{s}","count":{d},"detail_dropped_count":{d},"first_timestamp_ns":{d},"last_timestamp_ns":{d}}}
        \\
    , .{
        tagName(incident.ConnectionReason, value.reason_raw),
        tagName(incident.SourceSite, value.source_site_raw),
        value.count,
        value.detail_dropped_count,
        value.first_timestamp_ns,
        value.last_timestamp_ns,
    });
}

test "CR0b cli incidents 파싱은 닫힌 문법만 받는다" {
    try std.testing.expectEqual(Parsed.help, try parse(&.{"--help"}));
    try std.testing.expectEqual(Parsed.help, try parse(&.{ "list", "-h" }));
    try std.testing.expectError(error.MissingSubcommand, parse(&.{}));
    try std.testing.expectError(error.UnknownSubcommand, parse(&.{"delete"}));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "list", "--all" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "list", "--limit" }));
    try std.testing.expectError(error.InvalidLimit, parse(&.{ "list", "--limit", "0" }));
    try std.testing.expectError(error.InvalidLimit, parse(&.{ "list", "--limit", "x" }));

    const plain = try parse(&.{"list"});
    try std.testing.expect(!plain.list.json);
    try std.testing.expectEqual(default_limit, plain.list.limit);

    const full = try parse(&.{ "list", "--json", "--limit", "3" });
    try std.testing.expect(full.list.json);
    try std.testing.expectEqual(@as(usize, 3), full.list.limit);
}

test "CR0b cli incidents 포맷은 raw가 아니라 닫힌 이름을 찍는다" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var value: incident.ConnectionIncident = .{
        .flags = 0x04,
        .incident_id = .{ .app_instance_nonce = 0x1234, .sequence = 1 },
        .timestamp_ns = 7,
        .host_id = 0xabcd,
        .host_adapter_generation = 2,
        .connection_generation = 1,
        .wire_major = 2,
        .reason_raw = @intFromEnum(incident.ConnectionReason.local_invariant_violation),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(incident.SourceSite.client_read),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
        .last_success_request_id = 0,
        .pending_request_count = 0,
        .pending_stream_count = 0,
        .pending_event_count = 6,
        .queue_item_count = 0,
        .queue_bytes = 0,
        .outbound_offset = 0,
        .outbound_length = 0,
        .controller_generation = 0,
        .upgrade_epoch = 0,
        .first_timestamp_ns = 7,
        .last_timestamp_ns = 7,
    };
    try writeIncident(&writer, value);
    const line = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, line, "local_invariant_violation") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "client_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "0/0/6") != null);

    // 닫힌 집합 밖의 raw는 숫자로 흘려보내지 않고 "?"로 못박는다.
    writer = std.Io.Writer.fixed(&buffer);
    value.source_site_raw = 99;
    try writeIncident(&writer, value);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "?") != null);
}
