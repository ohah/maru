//! `maru incidents`의 **impure 짝** — 디렉토리 열거·파일 읽기·digest 검증. 순수 절반(파싱·포맷)은
//! `cli/incidents.zig`가 갖는다(cli/browser.zig ↔ cli/browser/run.zig와 같은 분할).
//!
//! **정렬 축이 파일 mtime이 아니라 레코드의 `timestamp_ns`인 이유**: 파일 시각은 복사·touch·백업으로 바뀌지만
//! 레코드 안의 시각은 봉투 digest에 봉인돼 있다. 진단은 봉인된 값을 믿어야 한다.

const std = @import("std");
const incidents = @import("incidents.zig");
const incident = @import("../observability/connection_incident.zig");

pub const relative_dir = ".cache/maru/incidents";

const Record = union(enum) {
    incident: incident.ConnectionIncident,
    aggregate: incident.IncidentAggregate,

    fn sortKey(self: Record) i128 {
        return switch (self) {
            .incident => |value| value.timestamp_ns,
            .aggregate => |value| value.last_timestamp_ns,
        };
    }
};

fn newerFirst(_: void, left: Record, right: Record) bool {
    return left.sortKey() > right.sortKey();
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: incidents.List,
    home: []const u8,
    cache_base: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // 경로 규칙의 단일 출처는 user_paths.cacheBaseFor 다 — 여기서 XDG 판정을 다시 구현하지 않는다.
    const dir_path = if (cache_base) |base|
        try std.fmt.allocPrint(allocator, "{s}/maru/incidents", .{base})
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, relative_dir });
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        try stderr.print("maru: no incident directory at {s}\n", .{dir_path});
        try stderr.flush();
        return;
    };
    defer dir.close(io);

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(allocator);
    // 손상되거나 낯선 파일은 조용히 버리지 않고 센다 — "0건"과 "읽을 수 없었다"는 다른 사실이다.
    var rejected: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".incident")) continue;
        const bytes = dir.readFileAlloc(io, entry.name, allocator, .limited(incident.envelope_size + 1)) catch {
            rejected += 1;
            continue;
        };
        defer allocator.free(bytes);
        if (bytes.len != incident.envelope_size) {
            rejected += 1;
            continue;
        }
        const decoded = incident.decodeEnvelope(bytes[0..incident.envelope_size]) catch {
            rejected += 1;
            continue;
        };
        try records.append(allocator, switch (decoded) {
            .incident => |value| .{ .incident = value },
            .aggregate => |value| .{ .aggregate = value },
        });
    }

    std.mem.sort(Record, records.items, {}, newerFirst);
    const shown = @min(request.limit, records.items.len);

    if (!request.json and shown != 0) try incidents.writeHeader(stdout);
    var aggregates: usize = 0;
    for (records.items[0..shown]) |record| switch (record) {
        .incident => |value| if (request.json)
            try incidents.writeIncidentJson(stdout, value)
        else
            try incidents.writeIncident(stdout, value),
        .aggregate => |value| {
            aggregates += 1;
            if (request.json) try incidents.writeAggregateJson(stdout, value);
        },
    };

    if (!request.json) {
        if (records.items.len == 0) {
            try stdout.writeAll("no incident records\n");
        } else {
            try stdout.print(
                "\n{d} record(s) shown of {d}; {d} aggregate row(s) hidden (use --json)\n",
                .{ shown, records.items.len, aggregates },
            );
        }
        if (rejected != 0)
            try stdout.print("{d} file(s) rejected: wrong size or failed digest/schema check\n", .{rejected});
    }
    try stdout.flush();
}
