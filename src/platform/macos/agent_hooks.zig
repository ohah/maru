//! 에이전트 세션 훅 매핑 — claude/codex의 **공식 훅**으로 "이 팬(Term)의 에이전트가 쓰는 세션 트랜스크립트가
//! 어느 파일인지"를 정확히 잇는다. 옛 방식(cwd+mtime 추측·CLAUDE_CODE_SESSION_ID env 읽기)은 같은 cwd 다중
//! 세션에서 섞이고 env는 상속·codex 미지원이라 취약했다(docs/agent-session.md "세션 파일 찾기").
//!
//! 골격(claude·codex 공통):
//!   1) maru가 각 팬 셸에 `MARU_PANE_ID=<surface.id>`를 주입(pty/macos.zig appendParentEnv).
//!   2) maru가 시작 시 claude(`~/.claude/settings.json`)·codex(`~/.codex/hooks.json`)의 `hooks`에
//!      SessionStart·UserPromptSubmit·Stop 훅을 등록한다(ensureRegistered). 훅 command는 **인라인 셸 한 줄**:
//!      stdin(JSON payload = transcript_path 포함)을 `<config>/maru/agent-sessions/$MARU_PANE_ID`로 덤프한다
//!      (jq 등 의존성 0). 여러 이벤트에 걸어, 등록 이전에 실행 중이던 세션도 다음 활동에 매핑된다(폴백 불필요).
//!   3) maru가 `term.surface.id`로 그 파일을 읽어(readMapping) JSON에서 `transcript_path`를 뽑아 그 파일을
//!      직접 tail-read한다(agent_session.poll).
//!
//! 안전: settings.json/hooks.json은 **파싱→(마커 없으면)병합→백업→atomic write**. 마커가 이미 있으면 재작성
//! 안 함(사용자 포맷 보존). 파싱 실패면 건드리지 않는다(사용자 config 보호). 전 과정 best-effort(실패는 조용히
//! degrade — 훅 없으면 그 세션이 안 뜰 뿐, maru는 정상).

const std = @import("std");

/// 훅을 걸 이벤트(claude·codex 공통 이름, 실측/문서 확인). SessionStart=세션 시작/resume, UserPromptSubmit·Stop=매 턴.
/// 매 턴 이벤트 덕에 등록 전부터 돌던 세션도 다음 프롬프트/응답완료에 매핑된다(cwd+mtime 폴백 없이 커버).
const hook_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop" };

/// idempotency 마커 — 등록된 훅 command 끝 주석. 재실행 시 raw config에 이게 있으면 재등록 skip(포맷 보존).
const marker = "MARU_PANE_MAP_HOOK";

const max_path = std.fs.max_path_bytes;

/// `<config>/maru` 절대경로를 out에 쓴다. `$XDG_CONFIG_HOME` 있으면 `<xdg>/maru`, 없으면 `$HOME/.config/maru`.
fn maruConfigDir(out: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const xdg = std.mem.span(x);
        if (xdg.len > 0) return std.fmt.bufPrint(out, "{s}/maru", .{xdg}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(out, "{s}/.config/maru", .{std.mem.span(home)}) catch null;
}

/// 세션 매핑 dir `<config>/maru/agent-sessions` 절대경로.
pub fn mappingsDir(out: []u8) ?[]const u8 {
    var cfg_buf: [max_path]u8 = undefined;
    const cfg = maruConfigDir(&cfg_buf) orelse return null;
    return std.fmt.bufPrint(out, "{s}/agent-sessions", .{cfg}) catch null;
}

/// 훅 command(인라인 셸)를 out에 쓴다. MARU_PANE_ID가 있으면 stdin을 `<dir>/$MARU_PANE_ID`로, 없으면 소비만.
/// dir을 절대경로로 박아 훅(셸)과 maru가 XDG override에도 같은 경로를 본다. 끝에 마커 주석(idempotency).
fn buildCommand(out: []u8, dir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        out,
        "if [ -n \"$MARU_PANE_ID\" ]; then mkdir -p \"{s}\" 2>/dev/null; cat > \"{s}/$MARU_PANE_ID\"; else cat >/dev/null; fi # {s}",
        .{ dir, dir, marker },
    ) catch null;
}

/// 에이전트 config 파일 경로. claude=`<CLAUDE_CONFIG_DIR|$HOME/.claude>/settings.json`,
/// codex=`<CODEX_HOME|$HOME/.codex>/hooks.json`.
fn agentConfigPath(out: []u8, home_env: [:0]const u8, home_sub: []const u8, file: []const u8) ?[]const u8 {
    if (std.c.getenv(home_env)) |d| {
        const dir = std.mem.span(d);
        if (dir.len > 0) return std.fmt.bufPrint(out, "{s}/{s}", .{ dir, file }) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(out, "{s}/{s}/{s}", .{ std.mem.span(home), home_sub, file }) catch null;
}

/// 등록 모드. `add_if_absent`=마커 없을 때만 추가(시작 시). `force`=기존 maru 훅(마커) 제거 후 현재 command로 재추가
/// (경로/포맷이 바뀐 stale 훅 복구). `remove`=maru 훅 제거만(언인스톨).
const Mode = enum { add_if_absent, force, remove };

/// 시작 시 1회: **매핑 dir 정리** + claude/codex 훅 등록(idempotent). best-effort(실패해도 무해 — 훅 없으면 그 세션만
/// 안 뜸). clearMappings는 이전 실행의 stale 매핑을 비운다(surface.id는 재시작마다 1부터라 재사용) — **시작 전용**.
pub fn setup(io: std.Io, allocator: std.mem.Allocator) void {
    clearMappings(io);
    applyToConfigs(io, allocator, .add_if_absent);
}

/// 수동 복구(커맨드 팔레트 "Re-register"): 훅을 **강제 재등록**한다 — 기존 maru 훅(마커)을 제거하고 현재 command로
/// 다시 넣어, 경로가 바뀌었거나(다른 XDG/HOME) command 포맷이 갱신된 stale 훅을 고친다. **clearMappings는 안 한다** —
/// 돌고 있는 팬들의 매핑을 날리지 않게(리뷰: setup 재사용이 매핑을 지우던 버그 수정).
pub fn reregister(io: std.Io, allocator: std.mem.Allocator) void {
    applyToConfigs(io, allocator, .force);
}

/// 수동 언인스톨(커맨드 팔레트 "Unregister"): claude/codex config에서 maru 훅(마커)만 제거한다. 다른 훅·키는 보존.
pub fn unregister(io: std.Io, allocator: std.mem.Allocator) void {
    applyToConfigs(io, allocator, .remove);
}

/// claude·codex config 각각에 모드를 적용한다. cmd_buf는 dir을 2회 담으므로(+셸 텍스트·마커) 넉넉히 잡아 오버플로로
/// 등록이 조용히 스킵되지 않게 한다(리뷰 지적).
fn applyToConfigs(io: std.Io, allocator: std.mem.Allocator, mode: Mode) void {
    var dir_buf: [max_path]u8 = undefined;
    const dir = mappingsDir(&dir_buf) orelse return;
    var cmd_buf: [max_path * 2 + 256]u8 = undefined;
    const command = buildCommand(&cmd_buf, dir) orelse return;

    var path_buf: [max_path]u8 = undefined;
    if (agentConfigPath(&path_buf, "CLAUDE_CONFIG_DIR", ".claude", "settings.json")) |p| {
        applyToConfig(io, allocator, p, command, mode);
    }
    var path_buf2: [max_path]u8 = undefined;
    if (agentConfigPath(&path_buf2, "CODEX_HOME", ".codex", "hooks.json")) |p| {
        applyToConfig(io, allocator, p, command, mode);
    }
}

/// 매핑 dir을 비우고 새로 만든다(stale 방지 — **시작 시에만**, reregister는 안 부름). 실패는 무시(훅 command가 mkdir -p
/// 로 자체 생성하므로).
fn clearMappings(io: std.Io) void {
    var dir_buf: [max_path]u8 = undefined;
    const dir = mappingsDir(&dir_buf) orelse return;
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
}

/// config_path에 모드를 적용한다. **읽기 오류(EACCES·>4MB)와 파일 없음을 구분**한다 — 없으면(`FileNotFound`) `{}`에서
/// 시작하고, 그 외 읽기 오류면 **아무것도 안 한다**(사용자 config를 minimal로 덮어쓰지 않게 — 리뷰 지적). 병합/제거
/// 로직은 computeMergedJson(순수). 첫 변경 시 원본 백업.
fn applyToConfig(io: std.Io, allocator: std.mem.Allocator, config_path: []const u8, command: []const u8, mode: Mode) void {
    const raw: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => "", // 없음 → 아래에서 `{}`로 시작
        else => return, // EACCES·StreamTooLong 등 — 읽을 수 없으면 손대지 않는다(덮어쓰기 방지)
    };
    const had_file = raw.len > 0;
    defer if (had_file) allocator.free(raw);

    const merged = computeMergedJson(allocator, raw, command, mode) orelse return; // null = 변경 불필요/불가
    defer allocator.free(merged);
    if (had_file) backup(io, allocator, config_path, raw); // 첫 변경 시 원본 백업(안전망)
    atomicWrite(io, config_path, merged) catch {};
}

/// raw에 모드대로 훅 command를 병합/제거한 JSON을 gpa로 할당해 돌려준다. **순수**(파일 I/O 없음). null=변경 불필요/불가.
/// - `add_if_absent`: 이미 마커 있으면 null(무변경·포맷 보존). 없으면 각 이벤트에 우리 group 추가.
/// - `force`: 각 이벤트에서 기존 maru group(마커) 제거 후 현재 command로 재추가(stale 복구).
/// - `remove`: 각 이벤트에서 maru group 제거만. 제거할 게 없으면(마커 없음·hooks 없음) null.
/// 파싱 실패·최상위 비-object·hooks 비-object면 null(사용자 config 보호). 기존 다른 훅/키는 보존한다.
fn computeMergedJson(gpa: std.mem.Allocator, raw: []const u8, command: []const u8, mode: Mode) ?[]u8 {
    const has_marker = raw.len > 0 and std.mem.indexOf(u8, raw, marker) != null;
    switch (mode) {
        .add_if_absent => if (has_marker) return null, // 이미 등록됨 → 무변경(포맷 보존)
        .remove => if (!has_marker) return null, // 뗄 게 없음
        .force => {}, // 항상 진행(제거+재추가)
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    var root: std.json.Value = undefined;
    if (raw.len > 0) {
        parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return null;
        root = parsed.?.value;
        if (root != .object) return null;
    } else {
        root = .{ .object = .empty };
    }

    // root.object["hooks"]를 object로 확보(ObjectMap은 unmanaged — put에 arena 전달). remove인데 hooks가 없으면 무변경.
    var hooks_ptr: *std.json.ObjectMap = blk: {
        if (root.object.getPtr("hooks")) |v| {
            if (v.* != .object) return null; // hooks가 object가 아니면 건드리지 않음
            break :blk &v.object;
        }
        if (mode == .remove) return null; // 뗄 hooks 자체가 없음
        root.object.put(arena, "hooks", .{ .object = .empty }) catch return null;
        break :blk &root.object.getPtr("hooks").?.object;
    };

    for (hook_events) |ev| {
        // force/remove: 이 이벤트의 기존 maru group(마커) 제거(제자리).
        if (mode != .add_if_absent) {
            if (hooks_ptr.getPtr(ev)) |v| {
                if (v.* == .array) removeMaruGroups(&v.array);
            }
        }
        if (mode == .remove) continue; // 제거만 — 추가 안 함
        // add_if_absent/force: 현재 command group 추가(없으면 이벤트 배열 생성). 비-array면 그 이벤트만 skip.
        var arr_ptr: *std.json.Array = brk: {
            if (hooks_ptr.getPtr(ev)) |v| {
                if (v.* != .array) continue;
                break :brk &v.array;
            }
            hooks_ptr.put(arena, ev, .{ .array = std.json.Array.init(arena) }) catch continue;
            break :brk &hooks_ptr.getPtr(ev).?.array;
        };
        const group = makeGroup(arena, command) catch continue;
        arr_ptr.append(group) catch continue;
    }

    return std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 }) catch null;
}

/// 이벤트 배열에서 maru group(어떤 hook의 command가 마커 포함)을 제자리 제거한다(managed Array orderedRemove).
fn removeMaruGroups(arr: *std.json.Array) void {
    var i: usize = 0;
    while (i < arr.items.len) {
        if (groupIsMaru(arr.items[i])) {
            _ = arr.orderedRemove(i);
        } else i += 1;
    }
}

/// group(`{hooks:[{type,command}]}`)의 어떤 hook command가 마커를 포함하면 maru가 넣은 것.
fn groupIsMaru(group: std.json.Value) bool {
    const obj = switch (group) {
        .object => |o| o,
        else => return false,
    };
    const hooks = obj.get("hooks") orelse return false;
    const arr = switch (hooks) {
        .array => |a| a,
        else => return false,
    };
    for (arr.items) |h| {
        const ho = switch (h) {
            .object => |o| o,
            else => continue,
        };
        const cmd = ho.get("command") orelse continue;
        const s = switch (cmd) {
            .string => |x| x,
            else => continue,
        };
        if (std.mem.indexOf(u8, s, marker) != null) return true;
    }
    return false;
}

/// `{ "hooks": [ { "type": "command", "command": <command> } ] }` Value를 arena에 만든다(이벤트 배열에 추가할 group).
fn makeGroup(arena: std.mem.Allocator, command: []const u8) !std.json.Value {
    var inner: std.json.ObjectMap = .empty;
    try inner.put(arena, "type", .{ .string = "command" });
    try inner.put(arena, "command", .{ .string = command });
    var arr = std.json.Array.init(arena);
    try arr.append(.{ .object = inner });
    var group: std.json.ObjectMap = .empty;
    try group.put(arena, "hooks", .{ .array = arr });
    return .{ .object = group };
}

/// 원본을 `<path>.maru-backup`으로 복사(첫 등록 시 1회 안전망). best-effort.
fn backup(io: std.Io, allocator: std.mem.Allocator, config_path: []const u8, raw: []const u8) void {
    var buf: [max_path]u8 = undefined;
    const bpath = std.fmt.bufPrint(&buf, "{s}.maru-backup", .{config_path}) catch return;
    _ = allocator;
    atomicWrite(io, bpath, raw) catch {};
}

/// temp + replace(rename) 원자적 쓰기 — 부분 쓰기가 원본을 손상하지 않게(app_session.zig resetAllSettings와 같은 규약).
fn atomicWrite(io: std.Io, path: []const u8, data: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);
    var wbuf: [4096]u8 = undefined;
    var fw = af.file.writer(io, &wbuf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
    try af.replace(io);
}

/// `term.surface.id`(pane_id)로 매핑 파일을 읽어 JSON에서 `transcript_path`를 뽑아 out에 복사해 돌려준다.
/// 파일 없음/파싱 실패/필드 없음이면 null(호출자는 그 팬 상태를 unknown으로). tick 스레드에서 poll마다 호출.
pub fn readMapping(io: std.Io, allocator: std.mem.Allocator, pane_id: u64, out: []u8) ?[]const u8 {
    var dir_buf: [max_path]u8 = undefined;
    const dir = mappingsDir(&dir_buf) orelse return null;
    var path_buf: [max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ dir, pane_id }) catch return null;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 << 10)) catch return null;
    defer allocator.free(data);
    return extractTranscriptPath(allocator, data, out);
}

/// 훅이 덤프한 payload JSON에서 `transcript_path` 문자열을 뽑아 out에 복사(순수 — 테스트 가능). 없으면 null.
fn extractTranscriptPath(allocator: std.mem.Allocator, data: []const u8, out: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const tp = obj.get("transcript_path") orelse return null;
    const s = switch (tp) {
        .string => |x| x,
        else => return null, // codex는 일부 이벤트에서 null일 수 있음 → 그 이벤트는 무시(다음 이벤트가 채움)
    };
    // 매핑 파일은 팬 셸의 아무 프로세스나 쓸 수 있으므로 경로를 방어적으로 검증한다(옛 isBasenameSafe 대체) — maru가
    // tick마다 stat·tail-read하는 대상이라, **절대경로 + `.jsonl` 확장자 + `..` 없음**만 허용해 임의 경로/traversal을 막는다.
    if (s.len == 0 or s.len > out.len) return null;
    if (s[0] != '/') return null; // 절대경로만
    if (!std.mem.endsWith(u8, s, ".jsonl")) return null; // 트랜스크립트 확장자
    if (std.mem.indexOf(u8, s, "..") != null) return null; // 상위 경로 조작 거부
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

test "extractTranscriptPath: payload JSON에서 transcript_path 추출" {
    const a = std.testing.allocator;
    var out: [max_path]u8 = undefined;
    const data =
        \\{"session_id":"5fff","transcript_path":"/Users/x/.claude/projects/-a-b/5fff.jsonl","cwd":"/a/b","hook_event_name":"SessionStart"}
    ;
    try std.testing.expectEqualStrings("/Users/x/.claude/projects/-a-b/5fff.jsonl", extractTranscriptPath(a, data, &out).?);
    // transcript_path 없음 → null.
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "{\"session_id\":\"x\"}", &out));
    // 비-object / 깨진 JSON → null(크래시 없음).
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "[1,2,3]", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "not json", &out));
    // null transcript_path(codex가 아직 미기록) → null.
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "{\"transcript_path\":null}", &out));
    // 경로 방어(옛 isBasenameSafe 대체): 상대경로·비-.jsonl·`..` 조작은 거부(임의 경로/traversal 방지).
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "{\"transcript_path\":\"relative/x.jsonl\"}", &out)); // 상대경로
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "{\"transcript_path\":\"/etc/passwd\"}", &out)); // 비-.jsonl
    try std.testing.expectEqual(@as(?[]const u8, null), extractTranscriptPath(a, "{\"transcript_path\":\"/a/../../etc/x.jsonl\"}", &out)); // `..` 조작
}

test "computeMergedJson add: 빈 config에서 hooks 3이벤트 등록" {
    const a = std.testing.allocator;
    const cmd = "echo hi # " ++ marker;
    const merged = computeMergedJson(a, "", cmd, .add_if_absent).?;
    defer a.free(merged);
    // 3 이벤트 + command + 마커 포함.
    for (hook_events) |ev| try std.testing.expect(std.mem.indexOf(u8, merged, ev) != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"command\"") != null);
    // 결과가 다시 파싱되는 유효 JSON인지.
    const reparse = std.json.parseFromSlice(std.json.Value, a, merged, .{}) catch return error.TestUnexpectedResult;
    reparse.deinit();
}

test "computeMergedJson add: 이미 마커 있으면 null(idempotent, 포맷 보존)" {
    const a = std.testing.allocator;
    const cmd = "echo hi # " ++ marker;
    const existing = "{\n  \"hooks\": { \"SessionStart\": [ {\"hooks\":[{\"type\":\"command\",\"command\":\"x # " ++ marker ++ "\"}]} ] }\n}";
    try std.testing.expectEqual(@as(?[]u8, null), computeMergedJson(a, existing, cmd, .add_if_absent));
}

test "computeMergedJson add: 사용자 기존 훅/키 보존 + 우리 것 추가" {
    const a = std.testing.allocator;
    const cmd = "echo hi # " ++ marker;
    // 사용자가 이미 다른 hooks + 최상위 다른 키를 가진 경우.
    const existing =
        \\{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"user-script"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard"}]}]}}
    ;
    const merged = computeMergedJson(a, existing, cmd, .add_if_absent).?;
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"model\"") != null); // 최상위 다른 키 보존
    try std.testing.expect(std.mem.indexOf(u8, merged, "user-script") != null); // 기존 SessionStart 훅 보존
    try std.testing.expect(std.mem.indexOf(u8, merged, "guard") != null); // 기존 PreToolUse 보존
    try std.testing.expect(std.mem.indexOf(u8, merged, marker) != null); // 우리 것 추가
    try std.testing.expect(std.mem.indexOf(u8, merged, "UserPromptSubmit") != null); // 우리가 새 이벤트도 추가
}

test "computeMergedJson add: 최상위 비-object/파싱 실패면 null(사용자 config 보호)" {
    const a = std.testing.allocator;
    const cmd = "echo hi # " ++ marker;
    try std.testing.expectEqual(@as(?[]u8, null), computeMergedJson(a, "[1,2,3]", cmd, .add_if_absent)); // 배열
    try std.testing.expectEqual(@as(?[]u8, null), computeMergedJson(a, "not json", cmd, .add_if_absent)); // 깨짐
    // hooks가 object가 아니면 null.
    try std.testing.expectEqual(@as(?[]u8, null), computeMergedJson(a, "{\"hooks\":[]}", cmd, .add_if_absent));
}

test "computeMergedJson force: stale maru 훅 제거 후 새 command로 재등록(복구)" {
    const a = std.testing.allocator;
    // 옛 command(경로가 다름)가 마커와 함께 이미 등록돼 있다. force는 이걸 제거하고 새 command를 넣어야 한다.
    const old_cmd_marker = "cat > /OLD/DIR/$MARU_PANE_ID # " ++ marker;
    const existing =
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"user-keep"}]},{"hooks":[{"type":"command","command":"OLDPLACEHOLDER"}]}]}}
    ;
    var buf: [512]u8 = undefined;
    const with_old = try std.mem.replaceOwned(u8, a, existing, "OLDPLACEHOLDER", old_cmd_marker);
    defer a.free(with_old);
    _ = &buf;
    const new_cmd = "cat > /NEW/DIR/$MARU_PANE_ID # " ++ marker;
    const merged = computeMergedJson(a, with_old, new_cmd, .force).?;
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "/OLD/DIR") == null); // 옛 maru 훅 제거됨
    try std.testing.expect(std.mem.indexOf(u8, merged, "/NEW/DIR") != null); // 새 command 등록됨
    try std.testing.expect(std.mem.indexOf(u8, merged, "user-keep") != null); // 사용자 훅은 보존
    // 마커가 정확히 이벤트 수만큼(중복 없이) — force가 제거 후 1개씩만 재추가.
    var count: usize = 0;
    var it = std.mem.window(u8, merged, marker.len, 1);
    while (it.next()) |w| : (count += if (std.mem.eql(u8, w, marker)) 1 else 0) {}
    try std.testing.expectEqual(hook_events.len, count);
}

test "computeMergedJson remove: maru 훅만 제거, 사용자 훅 보존. 마커 없으면 null" {
    const a = std.testing.allocator;
    const existing =
        \\{"model":"x","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"user-keep"}]},{"hooks":[{"type":"command","command":"maru # MARU_PANE_MAP_HOOK"}]}]}}
    ;
    const merged = computeMergedJson(a, existing, "", .remove).?;
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, marker) == null); // maru 훅 제거
    try std.testing.expect(std.mem.indexOf(u8, merged, "user-keep") != null); // 사용자 훅 보존
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"model\"") != null); // 다른 키 보존
    // 마커가 없으면 remove는 null(무변경).
    try std.testing.expectEqual(@as(?[]u8, null), computeMergedJson(a, "{\"hooks\":{}}", "", .remove));
    try std.testing.expectEqual(@as(?[]u8, null), computeMergedJson(a, "", "", .remove));
}

test "buildCommand: 마커 + dir 임베드 + stdin 소비 분기" {
    var buf: [max_path * 2]u8 = undefined;
    const cmd = buildCommand(&buf, "/home/u/.config/maru/agent-sessions").?;
    try std.testing.expect(std.mem.indexOf(u8, cmd, marker) != null); // idempotency 마커
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$MARU_PANE_ID") != null); // 팬 키
    try std.testing.expect(std.mem.indexOf(u8, cmd, "/home/u/.config/maru/agent-sessions/$MARU_PANE_ID") != null); // 절대경로 임베드
    try std.testing.expect(std.mem.indexOf(u8, cmd, "cat >/dev/null") != null); // 키 없을 때 stdin 소비(에이전트 블록 방지)
}
