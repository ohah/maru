//! 에이전트 세션 훅 매핑 — claude/codex의 **공식 훅**으로 "이 팬(Term)의 에이전트가 쓰는 세션 트랜스크립트가
//! 어느 파일인지"를 정확히 잇는다. 옛 방식(cwd+mtime 추측·CLAUDE_CODE_SESSION_ID env 읽기)은 같은 cwd 다중
//! 세션에서 섞이고 env는 상속·codex 미지원이라 취약했다(docs/agent-session.md "세션 파일 찾기").
//!
//! 골격(claude·codex 공통):
//!   1) maru가 각 Term 셸에 `MARU_AGENT_MAPPING_ID=<불투명 random id>`를 주입한다. 별도 maru 프로세스와도
//!      충돌하지 않으며, `MARU_PANE_ID=<surface.id>`는 컨트롤 플레인 selector로 그대로 유지한다.
//!   2) maru가 시작 시 claude(`~/.claude/settings.json`)·codex(`~/.codex/hooks.json`)의 `hooks`에
//!      SessionStart·UserPromptSubmit·Stop 훅을 등록한다(ensureRegistered). Claude는 시작 즉시, Codex 0.144.5의
//!      무프롬프트 fork는 첫 UserPromptSubmit/Stop에서 실제 새 id를 알렸다. 훅 command는 **인라인 셸 한 줄**:
//!      stdin(JSON payload = transcript_path 포함)을 `<config>/maru/agent-sessions/$MARU_AGENT_MAPPING_ID`로 덤프한다
//!      (jq 등 의존성 0). 여러 이벤트에 걸어, 등록 이전에 실행 중이던 세션도 다음 활동에 매핑된다(폴백 불필요).
//!   3) maru가 `term.rt.agent_mapping_id`로 그 파일을 읽어 JSON에서 `transcript_path`를 뽑아 그 파일을
//!      직접 tail-read한다(agent_session.poll).
//!
//! 안전: settings.json/hooks.json은 **파싱→(마커 없으면)병합→백업→atomic write**. 마커가 이미 있으면 재작성
//! 안 함(사용자 포맷 보존). 파싱 실패면 건드리지 않는다(사용자 config 보호). 전 과정 best-effort(실패는 조용히
//! degrade — 훅 없으면 그 세션이 안 뜰 뿐, maru는 정상).

const std = @import("std");
const maru = @import("maru");

/// 매핑이 어느 에이전트 것인지 검증할 때 쓰는 종류(claude/codex 세션 루트 구분). agent_session/agent_resume와 같은 타입.
pub const Kind = maru.app.agent_resume.Kind;

/// 두 provider에 등록할 이벤트 이름. Claude는 SessionStart에서 시작/resume/fork를 매핑한다. Codex 0.144.5 실측은
/// 무프롬프트 `fork` 시작 때 SessionStart를 발화하지 않고 첫 UserPromptSubmit/Stop에서 새 id를 매핑했다. 매 턴 이벤트
/// 덕에 이 차이와 등록 전부터 돌던 세션을 다음 활동에서 커버한다(cwd+mtime 폴백 없음).
const hook_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop" };

/// idempotency 마커 — 등록된 훅 command 끝 주석. 재실행 시 raw config에 이게 있으면 재등록 skip(포맷 보존).
const marker = "MARU_AGENT_MAP_HOOK_V2";
const legacy_marker = "MARU_PANE_MAP_HOOK";

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

/// 훅 command(인라인 셸)를 out에 쓴다. 새 앱의 Term별 MARU_AGENT_MAPPING_ID를 우선하고, 구버전 앱은
/// MARU_PANE_ID로 폴백한다. dir을 절대경로로 박아 훅과 maru가 XDG override에도 같은 경로를 본다.
fn buildCommand(out: []u8, dir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(
        out,
        "if [ -n \"$MARU_AGENT_MAPPING_ID\" ]; then key=\"$MARU_AGENT_MAPPING_ID\"; else key=\"$MARU_PANE_ID\"; fi; if [ -n \"$key\" ]; then mkdir -p \"{s}\" 2>/dev/null; cat > \"{s}/$key\"; else cat >/dev/null; fi # {s}",
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

/// 등록 모드. `add_if_absent`=마커 없을 때만 추가(시작 시). `force`=기존 maru 훅(마커)을 같은 index에서 현재 command로
/// 교체(경로/포맷이 바뀐 stale 훅 복구). `remove`=maru 훅 제거만(언인스톨).
const Mode = enum { add_if_absent, force, remove };

/// 시작 시 1회: **stale 매핑 정리** + claude/codex 훅 등록(idempotent). best-effort(실패해도 무해 — 훅 없으면 그 세션만
/// 안 뜸). pruneStaleMappings는 트랜스크립트가 사라진 매핑만 지우고 **살아있는 매핑은 보존**한다 — 매핑 dir이 모든
/// maru 인스턴스 공유라, 옛 clearMappings의 통째 wipe는 다른 프로세스의 라이브 세션을 파괴했다. 현재 key는 Term별
/// random mapping id라 프로세스 간 surface id가 같아도 충돌하지 않는다. **시작 전용**.
pub fn setup(io: std.Io, allocator: std.mem.Allocator) void {
    pruneStaleMappings(io, allocator);
    applyToConfigs(io, allocator, .add_if_absent);
}

/// 수동 복구(커맨드 팔레트 "Re-register"): 훅을 **강제 재등록**한다 — 기존 maru 훅(마커)을 같은 배열 index에서 현재
/// command로 교체해, 경로가 바뀌었거나(다른 XDG/HOME) command 포맷이 갱신된 stale 훅을 고친다. **매핑 정리는 안 한다** —
/// 돌고 있는 팬들의 매핑을 날리지 않게(리뷰: setup 재사용이 매핑을 지우던 버그 수정).
pub fn reregister(io: std.Io, allocator: std.mem.Allocator) void {
    applyToConfigs(io, allocator, .force);
}

/// 수동 언인스톨(커맨드 팔레트 "Unregister"): claude/codex config에서 maru 훅(마커)만 제거한다. 다른 훅·키는 보존.
pub fn unregister(io: std.Io, allocator: std.mem.Allocator) void {
    applyToConfigs(io, allocator, .remove);
}

/// Codex 진행 표시가 안 뜨는 **가장 흔한 원인** 감지 — codex 훅은 등록됐지만(우리 마커) Codex가 아직 그 훅을 **신뢰(trust)
/// 하지 않은** 상태. Codex는 보안상 사용자 훅(`~/.codex/hooks.json`)을 내용 해시로 검토하고, 신뢰 전엔 **발화하지 않는다**
/// (그래서 매핑이 안 써져 상태가 unknown → 사이드바 진행중이 안 뜸). 소스 확인(openai/codex
/// 56395bdd `hooks/src/engine/discovery.rs`):
/// 비관리 사용자 훅은 `trusted_hash == current_hash`일 때만 실행되고, 신뢰는 `config.toml`의 `[hooks.state]`에
/// `trusted_hash`로 저장된다. 그래서 "훅은 등록됐는데 config에 `trusted_hash`가 하나도 없음" = 미신뢰로 보는 coarse hint다.
/// 현재 훅의 hash/key를 계산하지 않으므로 다른 훅의 hash나 변경 전 stale hash가 있으면 감지하지 못하며, 그 경우의 정확한
/// Modified/Untrusted 판정과 재검토 UI는 Codex 자체에 맡긴다. best-effort: 훅 미등록/config 읽기 실패면 false(헛 안내 안 함).
/// **claude에는 이 신뢰 게이트가 없어** codex만 대상. 단일 출처 docs/agent-session.md "Codex 훅 신뢰".
pub fn codexHookNeedsTrust(io: std.Io, allocator: std.mem.Allocator) bool {
    var hooks_buf: [max_path]u8 = undefined;
    const hooks_path = agentConfigPath(&hooks_buf, "CODEX_HOME", ".codex", "hooks.json") orelse return false;
    var cfg_buf: [max_path]u8 = undefined;
    const cfg_path = agentConfigPath(&cfg_buf, "CODEX_HOME", ".codex", "config.toml") orelse return false;
    return codexHookTrustMissingAt(io, allocator, hooks_path, cfg_path);
}

/// codexHookNeedsTrust의 **경로 주입 순수 I/O** 코어(테스트가 tmp 파일로 검증). hooks_path에 maru 마커가 있고(등록됨)
/// cfg_path에 `trusted_hash`가 하나도 없으면(미신뢰) true. 훅 미등록/훅 읽기 실패면 false, config 부재는 미신뢰(true).
fn codexHookTrustMissingAt(io: std.Io, allocator: std.mem.Allocator, hooks_path: []const u8, cfg_path: []const u8) bool {
    // 1) 우리 codex 훅이 실제로 등록돼 있나(마커). 미등록이면 setup이 곧 등록하므로 안내 불필요.
    const hooks_raw = std.Io.Dir.cwd().readFileAlloc(io, hooks_path, allocator, .limited(4 << 20)) catch return false;
    defer allocator.free(hooks_raw);
    if (std.mem.indexOf(u8, hooks_raw, marker) == null) return false;

    // 2) Codex config.toml에 훅 신뢰(trusted_hash)가 하나라도 기록됐나. 없으면 미신뢰.
    const cfg_raw = std.Io.Dir.cwd().readFileAlloc(io, cfg_path, allocator, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => return true, // config 없음 = 신뢰 기록 전무 = 미신뢰
        else => return false, // 읽기 불가(EACCES 등) — 헛 안내 안 함
    };
    defer allocator.free(cfg_raw);
    return std.mem.indexOf(u8, cfg_raw, "trusted_hash") == null;
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

/// 시작 시: 매핑 dir을 순회해 **가리킨 트랜스크립트가 없어진(세션 gone)** 매핑만 지운다. 트랜스크립트가 살아있는
/// 매핑은 **보존**한다 — 매핑 dir(`<config>/maru/agent-sessions`)은 **모든 maru 인스턴스가 공유**하므로, 통째 삭제
/// (옛 clearMappings)는 **다른 프로세스에서 도는 라이브 세션의 매핑을 파괴**한다. 트랜스크립트가 사라진 stale 매핑은
/// [[missing self-heal]]과 별개로 시작 시 선제 정리한다.
fn pruneStaleMappings(io: std.Io, allocator: std.mem.Allocator) void {
    var dir_buf: [max_path]u8 = undefined;
    const dir = mappingsDir(&dir_buf) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    pruneStaleMappingsIn(io, allocator, dir);
}

/// `dir_path` 안의 매핑을 순회해 stale(트랜스크립트 부재/손상)만 삭제 — 순수 I/O(테스트가 tmp dir로 검증). 삭제-도중-순회
/// 문제를 피하려 stale 이름을 먼저 모은 뒤 순회 종료 후 지운다.
fn pruneStaleMappingsIn(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |s| allocator.free(s);
        stale.deinit(allocator);
    }

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        var path_buf: [max_path]u8 = undefined;
        const fpath = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const keep = blk: {
            const data = std.Io.Dir.cwd().readFileAlloc(io, fpath, allocator, .limited(256 << 10)) catch break :blk false;
            defer allocator.free(data);
            var tp_buf: [max_path]u8 = undefined;
            const tp = extractTranscriptPath(allocator, data, &tp_buf) orelse break :blk false; // transcript_path 없음(손상) → 삭제
            _ = std.Io.Dir.cwd().statFile(io, tp, .{}) catch break :blk false; // 트랜스크립트 부재(세션 gone) → 삭제
            break :blk true; // 트랜스크립트 존재 → 보존(다른 인스턴스 라이브 세션 보호)
        };
        if (!keep) {
            const name = allocator.dupe(u8, entry.name) catch continue; // entry.name은 iterator 버퍼(transient) → 복사
            stale.append(allocator, name) catch {
                allocator.free(name);
                continue;
            };
        }
    }

    // 순회 종료 후 삭제(삭제-도중-순회 UB 회피).
    for (stale.items) |name| {
        var path_buf: [max_path]u8 = undefined;
        const fpath = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
        std.Io.Dir.cwd().deleteFile(io, fpath) catch {};
    }
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
/// - `add_if_absent`: 현재 v2 마커면 null. 옛 MARU_PANE_MAP_HOOK이면 같은 배열 index에서 v2로 교체한다.
/// - `force`: 각 이벤트의 기존 maru group을 같은 index에서 현재 command로 교체하고, 없으면 추가한다(stale 복구).
/// - `remove`: 각 이벤트에서 maru group 제거만. 제거할 게 없으면(마커 없음·hooks 없음) null.
/// 파싱 실패·최상위 비-object·hooks 비-object면 null(사용자 config 보호). 기존 다른 훅/키는 보존한다.
fn computeMergedJson(gpa: std.mem.Allocator, raw: []const u8, command: []const u8, mode: Mode) ?[]u8 {
    const has_marker = raw.len > 0 and std.mem.indexOf(u8, raw, marker) != null;
    const has_legacy_marker = raw.len > 0 and std.mem.indexOf(u8, raw, legacy_marker) != null;
    const has_any_marker = has_marker or has_legacy_marker;
    switch (mode) {
        .add_if_absent => if (has_marker) return null, // 이미 등록됨 → 무변경(포맷 보존)
        .remove => if (!has_any_marker) return null, // 뗄 게 없음
        .force => {}, // 항상 진행(같은 index 교체, 없으면 추가)
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
        if (mode == .remove) {
            if (hooks_ptr.getPtr(ev)) |v| if (v.* == .array) removeMaruGroups(&v.array);
            continue;
        }
        // add_if_absent/force: 이벤트 배열을 확보한다. Codex의 hook state key가 group/handler 배열 index 기반이므로
        // legacy/current maru group은 삭제+끝 append하지 않고 아래에서 **같은 index**의 새 group으로 교체한다.
        var arr_ptr: *std.json.Array = brk: {
            if (hooks_ptr.getPtr(ev)) |v| {
                if (v.* != .array) continue;
                break :brk &v.array;
            }
            hooks_ptr.put(arena, ev, .{ .array = std.json.Array.init(arena) }) catch continue;
            break :brk &hooks_ptr.getPtr(ev).?.array;
        };
        var replaced = false;
        if (mode == .force or has_legacy_marker) {
            for (arr_ptr.items) |*existing| {
                if (!groupIsMaru(existing.*)) continue;
                existing.* = makeGroup(arena, command) catch continue;
                replaced = true;
            }
        }
        if (!replaced) {
            const group = makeGroup(arena, command) catch continue;
            arr_ptr.append(group) catch continue;
        }
    }

    return std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 }) catch null;
}

/// unregister에서 이벤트 배열의 maru group(어떤 hook의 command가 마커 포함)만 제거한다.
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
        if (std.mem.indexOf(u8, s, marker) != null or std.mem.indexOf(u8, s, legacy_marker) != null) return true;
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

/// `mapping_id`로 매핑 파일을 읽어 JSON `transcript_path`를 뽑아 out에 복사해 돌려준다 — 단 **stale 매핑을 걸러낸다**:
/// (1) 경로가 `kind`의 세션 루트 아래인가(claude=`.claude/projects`, codex=`.codex/sessions`) — 같은 Term에서
/// 키잉되므로, 같은 팬에서 codex→claude로 바뀌고 claude 훅 발화 전이면 codex 경로를 claude로 오파싱하는 걸 막는다.
/// (2) `pane_cwd`가 주어지면 payload `cwd`가 그 팬 cwd와 같은가 — 다른 폴더 세션의 stale 매핑을 막는다(restore에서 씀;
/// 라이브 poll은 null로 넘겨 cwd 체크 생략—self-heal). 파일 없음/파싱 실패/검증 실패면 null(호출자는 unknown/폴백).
/// Term의 세션 매핑 파일(`<dir>/<mapping_id>`)을 지운다 — 매핑된 트랜스크립트가 사라진(세션 gone) 걸 pollAgentState가
/// 감지했을 때 stale 매핑을 정리한다(docs/agent-session.md "매핑된 트랜스크립트 부재"). 새 세션은 provider의 다음
/// 세션 훅(Claude SessionStart, Codex UserPromptSubmit/Stop)이 새 매핑을 쓰므로 무해. best-effort(없으면 무시).
pub fn removeMapping(io: std.Io, mapping_id: u64) void {
    var dir_buf: [max_path]u8 = undefined;
    const dir = mappingsDir(&dir_buf) orelse return;
    removeMappingIn(io, dir, mapping_id);
}

/// 경로 주입 가능한 Term-owned mapping 정리 코어. 제품은 mappingsDir를, 테스트는 tmp dir를 넘긴다.
fn removeMappingIn(io: std.Io, dir: []const u8, mapping_id: u64) void {
    var path_buf: [max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ dir, mapping_id }) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn readMapping(io: std.Io, allocator: std.mem.Allocator, mapping_id: u64, kind: Kind, pane_cwd: ?[]const u8, out: []u8) ?[]const u8 {
    var dir_buf: [max_path]u8 = undefined;
    const dir = mappingsDir(&dir_buf) orelse return null;
    var path_buf: [max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ dir, mapping_id }) catch return null;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 << 10)) catch return null;
    defer allocator.free(data);

    const tp = extractTranscriptPath(allocator, data, out) orelse return null;
    // (1) kind 세션 루트 아래인지 — 교차-에이전트 stale 매핑 차단.
    var root_buf: [max_path]u8 = undefined;
    const root = agentSessionRoot(kind, &root_buf) orelse return null;
    if (!std.mem.startsWith(u8, tp, root)) return null;
    // (2) cwd 일치(restore에서만) — 교차-cwd stale 매핑 차단.
    if (pane_cwd) |pcwd| {
        var cwd_buf: [max_path]u8 = undefined;
        const mcwd = extractCwd(allocator, data, &cwd_buf) orelse return null;
        if (!std.mem.eql(u8, mcwd, pcwd)) return null;
    }
    return tp;
}

/// `kind`의 세션 루트(끝 `/` 포함) — claude=`<CLAUDE_CONFIG_DIR|~/.claude>/projects/`, codex=`<CODEX_HOME|~/.codex>/sessions/`.
/// readMapping이 transcript_path가 이 아래인지 확인해 교차-에이전트 stale 매핑을 거른다. 끝 `/`로 `projects-evil` 오매칭 방지.
fn agentSessionRoot(kind: Kind, out: []u8) ?[]const u8 {
    return switch (kind) {
        .claude => agentConfigPath(out, "CLAUDE_CONFIG_DIR", ".claude", "projects/"),
        .codex => agentConfigPath(out, "CODEX_HOME", ".codex", "sessions/"),
    };
}

/// 매핑 payload JSON에서 `cwd` 문자열을 뽑아 out에 복사(순수). 없으면 null.
fn extractCwd(allocator: std.mem.Allocator, data: []const u8, out: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const c = obj.get("cwd") orelse return null;
    const s = switch (c) {
        .string => |x| x,
        else => return null,
    };
    if (s.len == 0 or s.len > out.len) return null;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
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

test "extractCwd: payload JSON에서 cwd 추출(restore의 stale 매핑 cwd 대조용)" {
    const a = std.testing.allocator;
    var out: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("/Users/x/ws", extractCwd(a, "{\"cwd\":\"/Users/x/ws\",\"transcript_path\":\"/y.jsonl\"}", &out).?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractCwd(a, "{\"transcript_path\":\"/y.jsonl\"}", &out)); // cwd 없음
    try std.testing.expectEqual(@as(?[]const u8, null), extractCwd(a, "not json", &out));
}

test "agentSessionRoot: kind별 세션 루트가 끝 / 로 끝난다(교차-에이전트 경로 판별의 prefix)" {
    var out: [max_path]u8 = undefined;
    // claude=…/projects/, codex=…/sessions/ (env 유무와 무관하게 마지막 세그먼트 고정). readMapping이 이 prefix로
    // transcript_path를 startsWith 검사해 codex 경로를 claude로(또는 반대) 오파싱하는 stale 매핑을 거른다.
    try std.testing.expect(std.mem.endsWith(u8, agentSessionRoot(.claude, &out).?, "/projects/"));
    try std.testing.expect(std.mem.endsWith(u8, agentSessionRoot(.codex, &out).?, "/sessions/"));
}

// applyToConfig의 파일 I/O 경로를 temp dir 실파일로 고정한다 — 특히 **읽기 오류(>4MB)를 사용자 config 손상 없이
// abort**하는지(리뷰 최우선 지적)와, 없는 파일 생성·기존 파일 백업 생성을 검증한다.
test "applyToConfig: 없음→생성, 있음→백업+병합, 읽기오류(>4MB)→무접촉" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, ".zig-cache/tmp/{s}/settings.json", .{tmp.sub_path});
    const cmd = "echo x # " ++ marker;

    // 1) 없는 파일 → 훅 추가(마커 포함), 백업은 없음(had_file=false).
    applyToConfig(io, a, path, cmd, .add_if_absent);
    {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        defer a.free(data);
        try std.testing.expect(std.mem.indexOf(u8, data, marker) != null);
    }

    // 2) 기존 유효 config(마커 없음) → 훅 병합 + 원본 백업 생성. (마커 있는 위 결과를 사용자 config로 대체)
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"model\":\"keepme\"}" });
    applyToConfig(io, a, path, cmd, .add_if_absent);
    {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        defer a.free(data);
        try std.testing.expect(std.mem.indexOf(u8, data, marker) != null); // 훅 추가
        try std.testing.expect(std.mem.indexOf(u8, data, "keepme") != null); // 기존 키 보존
    }
    {
        var bbuf: [4096]u8 = undefined;
        const bpath = try std.fmt.bufPrint(&bbuf, "{s}.maru-backup", .{path});
        const bak = try std.Io.Dir.cwd().readFileAlloc(io, bpath, a, .limited(1 << 20));
        defer a.free(bak);
        try std.testing.expectEqualStrings("{\"model\":\"keepme\"}", bak); // 백업 = 원본
    }

    // 3) **읽기 오류(>4MB)** → readFileAlloc이 StreamTooLong로 실패 → abort(무접촉). 5MB 파일이 그대로 남아야 한다
    //    (minimal config로 덮어쓰지 않음 — 리뷰 최우선 버그 회귀 방지).
    const big = try a.alloc(u8, 5 << 20);
    defer a.free(big);
    @memset(big, 'x');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = big });
    applyToConfig(io, a, path, cmd, .add_if_absent);
    {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 << 20));
        defer a.free(data);
        try std.testing.expectEqual(@as(usize, 5 << 20), data.len); // 그대로 — 덮어쓰지 않음
    }
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

test "computeMergedJson add: surface-id legacy hook을 random mapping id v2로 한 번 업그레이드" {
    const a = std.testing.allocator;
    const cmd = "echo hi # " ++ marker;
    const existing = "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"old # " ++ legacy_marker ++ "\"}]}]}}";
    const merged = computeMergedJson(a, existing, cmd, .add_if_absent).?;
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, legacy_marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, marker) != null);
    for (hook_events) |ev| try std.testing.expect(std.mem.indexOf(u8, merged, ev) != null);
}

test "computeMergedJson add: legacy upgrade는 뒤 사용자 hook의 positional index를 보존" {
    const a = std.testing.allocator;
    const cmd = "echo hi # " ++ marker;
    const existing =
        "{\"hooks\":{\"SessionStart\":[" ++
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"old # " ++ legacy_marker ++ "\"}]}," ++
        "{\"hooks\":[{\"type\":\"command\",\"command\":\"user-after\"}]}]}}";
    const merged = computeMergedJson(a, existing, cmd, .add_if_absent).?;
    defer a.free(merged);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, merged, .{});
    defer parsed.deinit();
    const groups = parsed.value.object.get("hooks").?.object.get("SessionStart").?.array;
    try std.testing.expectEqual(@as(usize, 2), groups.items.len);
    try std.testing.expect(groupIsMaru(groups.items[0]));
    try std.testing.expect(!groupIsMaru(groups.items[1]));
    try std.testing.expect(std.mem.indexOf(u8, merged, marker).? < std.mem.indexOf(u8, merged, "user-after").?);
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
    // 마커가 정확히 이벤트 수만큼(중복 없이) — 기존 config의 이벤트별 maru group 1개를 같은 위치에서 교체.
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
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$MARU_AGENT_MAPPING_ID") != null); // 새 Term별 key 우선
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$MARU_PANE_ID") != null); // 구버전 앱 폴백
    try std.testing.expect(std.mem.indexOf(u8, cmd, "/home/u/.config/maru/agent-sessions/$key") != null); // 절대경로 임베드
    try std.testing.expect(std.mem.indexOf(u8, cmd, "cat >/dev/null") != null); // 키 없을 때 stdin 소비(에이전트 블록 방지)
}

test "pruneStaleMappingsIn: 트랜스크립트 없는 매핑만 지우고 살아있는 건 보존(multi-instance 안전)" {
    // 공유 매핑 dir을 통째 wipe하던 옛 clearMappings의 destructive 동작을 대체 — 다른 인스턴스의 라이브 세션(트랜스크립트
    // 존재)은 살리고, 트랜스크립트가 사라진(세션 gone)·손상된 매핑만 정리한다.
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel_base = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // extractTranscriptPath는 **절대경로 + .jsonl**만 허용(traversal 방어)하므로, JSON 안 transcript_path는 절대경로로 둔다.
    var cwd_buf: [max_path]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) unreachable;
    const cwd_abs = std.mem.sliceTo(&cwd_buf, 0);
    const abs_base = try std.fmt.allocPrint(ar, "{s}/{s}", .{ cwd_abs, rel_base });

    // 살아있는 트랜스크립트 파일(존재) — 이걸 가리키는 매핑은 보존돼야. 파일은 상대경로로 쓰고(같은 위치), JSON엔 절대경로.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(ar, "{s}/live-transcript.jsonl", .{rel_base}), .data = "{}" });
    const live_tp = try std.fmt.allocPrint(ar, "{s}/live-transcript.jsonl", .{abs_base});
    const gone_tp = try std.fmt.allocPrint(ar, "{s}/gone-transcript.jsonl", .{abs_base}); // 안 만듦 = 세션 gone

    const base = rel_base; // 매핑 dir/파일은 cwd-상대로 만든다(pruneStaleMappingsIn이 dir_path/name으로 접근).

    const map_dir = try std.fmt.allocPrint(ar, "{s}/agent-sessions", .{base});
    try std.Io.Dir.cwd().createDirPath(io, map_dir);
    const live_map = try std.fmt.allocPrint(ar, "{s}/2", .{map_dir}); // pane 2 = 라이브(보존)
    const gone_map = try std.fmt.allocPrint(ar, "{s}/3", .{map_dir}); // pane 3 = gone(삭제)
    const broken_map = try std.fmt.allocPrint(ar, "{s}/4", .{map_dir}); // pane 4 = transcript_path 없음(삭제)
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_map, .data = try std.fmt.allocPrint(ar, "{{\"transcript_path\":\"{s}\"}}", .{live_tp}) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gone_map, .data = try std.fmt.allocPrint(ar, "{{\"transcript_path\":\"{s}\"}}", .{gone_tp}) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = broken_map, .data = "{\"nope\":1}" });

    pruneStaleMappingsIn(io, a, map_dir);

    const exists = struct {
        fn f(i: std.Io, p: []const u8) bool {
            _ = std.Io.Dir.cwd().statFile(i, p, .{}) catch return false;
            return true;
        }
    }.f;
    try std.testing.expect(exists(io, live_map)); // 라이브 세션 매핑 보존(다른 인스턴스 보호)
    try std.testing.expect(!exists(io, gone_map)); // 세션 gone → 삭제
    try std.testing.expect(!exists(io, broken_map)); // 손상(transcript_path 없음) → 삭제
}

test "codexHookTrustMissingAt: 훅 등록+config에 trusted_hash 없음=미신뢰, 있음=신뢰, 미등록=안내안함" {
    // Codex는 훅을 신뢰(trusted_hash)해야 발화한다(docs/agent-session.md pinned upstream 확인) — 진행중 안 뜨는 흔한 원인.
    // 이 함수는 현재 hash를 계산하지 않는 coarse hint라 config에 hash가 하나라도 있으면 Codex 자체 판정에 맡긴다.
    // config에 신뢰 기록이 없으면 미신뢰(안내 대상), 있으면 신뢰(안내 안 함), 아예 미등록이면 setup이 곧 등록하므로 안내 안 함.
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const hooks_path = try std.fmt.allocPrint(ar, "{s}/hooks.json", .{base});
    const cfg_path = try std.fmt.allocPrint(ar, "{s}/config.toml", .{base});

    // 마커 있는 등록된 훅.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hooks_path, .data = "{\"hooks\":{}} # " ++ marker });

    // (1) config 없음 = 신뢰 기록 전무 = 미신뢰 → true(안내).
    try std.testing.expect(codexHookTrustMissingAt(io, a, hooks_path, cfg_path));

    // (2) config에 trusted_hash 없음 = 미신뢰 → true.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "model = \"gpt-5.5\"\n[projects.\"/x\"]\ntrust_level = \"trusted\"\n" });
    try std.testing.expect(codexHookTrustMissingAt(io, a, hooks_path, cfg_path));

    // (3) config에 trusted_hash 있음 = 신뢰 → false(안내 안 함).
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[hooks.state.\"x\"]\ntrusted_hash = \"abc123\"\n" });
    try std.testing.expect(!codexHookTrustMissingAt(io, a, hooks_path, cfg_path));

    // (4) 훅에 마커 없음(미등록) = 안내 안 함 → false.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = hooks_path, .data = "{\"hooks\":{}}" });
    try std.testing.expect(!codexHookTrustMissingAt(io, a, hooks_path, cfg_path));
}

test "removeMappingIn: Term-owned mapping만 지우고 다른 mapping은 보존" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}/agent-sessions", .{tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const owned = try std.fmt.allocPrint(ar, "{s}/42", .{dir});
    const other = try std.fmt.allocPrint(ar, "{s}/99", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = owned, .data = "owned" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = other, .data = "other" });

    removeMappingIn(io, dir, 42);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, owned, .{}));
    _ = try std.Io.Dir.cwd().statFile(io, other, .{});
}
