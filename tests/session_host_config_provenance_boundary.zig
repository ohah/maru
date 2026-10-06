//! Session default G1 config provenance source boundary.
//!
//! G1 owns parsing and G2 is the only product consumer of its provenance fields. This gate keeps
//! the parser singular and pins the deliberately opened G2 inventory rather than preserving the
//! obsolete pre-G2 assumption that provenance never leaves the config layer.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;
const build_source = @import("support/build_source.zig");

test "Session default G1 provenance boundary keeps one parser and the exact G2 consumer inventory" {
    const allocator = std.testing.allocator;
    const loader = try readSource(allocator, "src/config/loader.zig");
    defer allocator.free(loader);
    const schema = try readSource(allocator, "src/config/schema.zig");
    defer allocator.free(schema);
    const barrel = try readSource(allocator, "src/config.zig");
    defer allocator.free(barrel);
    const build = try build_source.read(allocator);
    defer allocator.free(build);
    const persistent = try readSource(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);
    const plan = try readSource(allocator, "docs/implementation-plan.md");
    defer allocator.free(plan);
    const verification = try readSource(allocator, "docs/verification-matrix.md");
    defer allocator.free(verification);
    const commands = try readSource(allocator, "docs/development-commands.md");
    defer allocator.free(commands);

    try expectOne(schema, "pub fn parseBool(value: []const u8) ?bool");
    try expectOne(loader, "schema.parseBool(value)");
    try expectOne(loader, "pub const SessionKeepAliveProvenance = union(enum)");
    try expectOne(loader, "pub const FileProvenance = enum");
    try expectOne(barrel, "pub const SessionKeepAliveProvenance = loader.SessionKeepAliveProvenance;");
    try expectOne(barrel, "pub const ConfigFileProvenance = loader.FileProvenance;");
    try expectOne(build, "\"test-session-host-config-provenance\"");
    try std.testing.expect(std.mem.indexOf(u8, persistent, "G1 loader provenance 계약") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "G1 config loader provenance") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification, "Session default G1 config provenance") != null);
    try expectOne(commands, "`zig build test-session-host-config-provenance`");

    // The session-host status is a current gate inventory, not a historical phase headline.
    // Keep the default and the locally-runnable versus provisioned-release boundary aligned
    // across the two normative documents so a closed slice cannot return to the backlog.
    try std.testing.expectEqual(@as(usize, 0), count(persistent, "현재 판정(2026-09-11 코드·gate 대조)"));
    try expectOne(plan, "현재 판정(2026-09-13 코드·gate 대조)");
    try expectOne(plan, "P1~P5의 일반 제품 경로와 ad-hoc gate, N3-R3 protected");
    try expectOne(verification, "P1~P5의 일반 제품 경로와 ad-hoc gate 및 P4 Notification Center transaction의 R3 workflow는 완료");
    try std.testing.expectEqual(@as(usize, 0), count(persistent, "상태: P3 core 구현, P4/P5 미완료"));
    try std.testing.expectEqual(@as(usize, 0), count(persistent, "default `false` opt-in 제품 계약"));
    try std.testing.expectEqual(@as(usize, 0), count(verification, "설정은 아직 기본 `false`다"));

    // G2 deliberately opens these projections in app_session/settings, plus the read-only v181
    // release baseline classifier. Exact counts include same-file tests; another product reader
    // must update this SSOT boundary rather than silently becoming another policy owner.
    //
    // 8th occurrence (2026-09-04): the G3 default-flip test asserts the provenance is `.absent`
    // for a config with no `session.keep-alive-after-quit` line. That is a **test assertion, not a
    // policy owner** — it reads the projection to prove the "no line -> built-in default" link that
    // the flip relies on. Kept counted here on purpose: this boundary is what forces the next
    // reader to come here and say which of the two it is.
    try std.testing.expectEqual(@as(usize, 8), try countOutsideConfig(allocator, "session_keep_alive_provenance"));
    //
    // file_provenance 21st·22nd (2026-10-02): the `workspace.restore` toggle
    // (`maru_macos_workspace_restore_enabled` in app_host_abi.zig) and its same-file test. **Diagnostic only,
    // not a policy owner** — the loader never errors for an unreadable/oversized file, so the toggle logs that
    // provenance; the restore decision still comes from `config.workspace.restore` alone.
    //
    // 23rd (2026-10-04): `logConfigDiagnostics` in app_session/settings.zig, shared by startup and Reload
    // Config. **Diagnostic only** for the same reason — it logs `config file unreadable|oversize` so a reload
    // that silently fell back to defaults leaves a line in app.log; no setting is chosen from it.
    //
    // 24th (2026-10-06): `reloadConfig` in app_session/settings.zig. **This one is a policy owner, on purpose**
    // — and only for *reload*: when the file exists but is unreadable or oversized, the loader returns defaults,
    // and reload now refuses to apply that parse and keeps the current settings (user decision). Startup still
    // takes the loader's defaults (nothing to keep), and a deleted file (`missing`) still reloads as defaults.
    // It chooses whether to *apply* a parse, never a setting value — the values still come from the one parser.
    try std.testing.expectEqual(@as(usize, 24), try countOutsideConfig(allocator, "file_provenance"));
}

fn countOutsideConfig(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .sym_link) return error.TestUnexpectedResult;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "config.zig") or std.mem.startsWith(u8, entry.path, "config/")) continue;
        const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn expectOne(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), count(haystack, needle));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}
