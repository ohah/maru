//! 사용자 설정 파일의 훅 상태를 보고 **무엇을 할지** 정하는 순수 판정(L2, I/O 없음).
//! 계약의 단일 출처는 [docs/agent-hooks.md](../../docs/agent-hooks.md) §5이고, 파일 읽기·쓰기·`flock`·
//! JSON 편집은 platform 이 한다. 여기서는 «상태 → 계획» 하나만 본다.
//!
//! **왜 판정을 떼어 놓는가**: 이 결정이 틀리면 사용자 홈의 파일이 상한다. 같은 계열의 선례가 그것을 실제로
//! 겪었다 — 상태 판정과 파일 I/O 가 엉킨 코드가 «읽기 실패» 를 «빈 설정» 으로 접어, 0 바이트 창에 걸리자
//! 사용자 `settings.json` 을 통째로 날렸다. 판정을 순수 층으로 빼면 그 분기들을 **파일 없이** 전수로 돌릴 수 있다.

const std = @import("std");
const command = @import("agent_hook_command.zig");

// ── provider 별 자리 ────────────────────────────────────────────────────────────────────────────
//
// **경로 규칙을 platform 이 추측하지 않게** 순수 층에 둔다. 두 provider 가 «환경 변수 우선, 없으면 홈 아래
// 숨김 폴더» 라는 같은 모양을 쓰는데, 이름만 다르다. platform 에 흩어 두면 한쪽만 고쳐지고 그 어긋남은
// «그 provider 만 설치가 안 됨» 으로 나타나 눈에 잘 안 띈다.

/// 설정 디렉터리를 가리키는 환경 변수 이름.
pub fn configDirEnv(provider: command.Provider) [:0]const u8 {
    return switch (provider) {
        .claude => "CLAUDE_CONFIG_DIR",
        .codex => "CODEX_HOME",
    };
}

/// 환경 변수가 없을 때 홈 아래에서 찾는 폴더 이름.
pub fn homeSubdir(provider: command.Provider) []const u8 {
    return switch (provider) {
        .claude => ".claude",
        .codex => ".codex",
    };
}

/// 훅 항목이 사는 파일 이름. claude 는 **다른 설정과 한 파일을 나눠 쓰고**(그래서 나머지 키를 반드시
/// 보존해야 한다), codex 는 훅 전용 파일이다.
pub fn hooksFileName(provider: command.Provider) []const u8 {
    return switch (provider) {
        .claude => "settings.json",
        .codex => "hooks.json",
    };
}

/// 설정 디렉터리 절대 경로. **빈 환경 변수는 «설정하지 않음» 과 같게 본다** — 빈 경로를 그대로 쓰면
/// 루트에 파일을 만든다.
pub fn configDir(provider: command.Provider, buf: []u8, env_value: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (env_value) |dir| {
        if (dir.len > 0) return std.fmt.bufPrint(buf, "{s}", .{dir}) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home orelse return null, homeSubdir(provider) }) catch null;
}

/// 어느 provider 의 세트든 넘지 않는 크기. 순수 층이라 할당하지 않으므로 고정 배열의 상한이 필요하다.
///
/// **손으로 적지 않고 세트에서 뽑는다.** 손으로 적으면 이벤트를 하나 더할 때 여기를 잊고, 그러면
/// `scan` 의 고정 배열이 범위를 넘어 터진다(실제로 그렇게 한 번 터졌다).
pub const max_events: usize = @max(command.claude_events.len, command.codex_events.len);

/// platform 이 설정 파일을 훑어 채우는 요약. **우리 항목만** 센다 — 사용자 항목은 세지 않는다(건드리지 않으므로).
pub const Known = struct {
    /// 우리 표식이 붙은 항목 수(모든 이벤트에 걸쳐).
    ours: usize = 0,
    /// 그중 커맨드 바이트가 **지금 만들 것과 같은** 항목 수. 경로·상한·표식이 바뀌면 이 수가 줄어든다.
    ours_current: usize = 0,
    /// **세트에 있는** 이벤트 중 우리 항목이 덮은 수(중복 제외). 세트보다 적으면 일부만 설치된 것이다.
    events_covered: usize = 0,
    /// **세트에 없는** 이벤트에 붙어 있는 우리 항목 수. 세트에서 이벤트를 뺐을 때(예: `PostToolUse`) 그
    /// 자리에 남은 우리 항목이 여기 잡힌다 — 개수만 비교하면 «6개를 덮었다» 로 보여 **잘못된 이벤트에 남은
    /// 항목이 영영 안 지워진다**. 0 이 아니면 걷어 내고 다시 넣는다.
    events_outside: usize = 0,
    /// 과거 표식 항목이 있는가. **건드리지 않는다**([persistent-session-host.md](../../docs/persistent-session-host.md)
    /// P1 — legacy 잔재를 자동 정리하지 않는다). 안내에만 쓴다.
    legacy_present: bool = false,
};

pub const State = union(enum) {
    /// 파일을 읽지 못했다(없음이 아니라 **파싱 실패·권한·부분 쓰기 중**). 여기서 «빈 설정» 으로 접으면
    /// 사용자 파일을 우리 것으로 덮어쓴다.
    unreadable,
    /// 파일이 아직 없다. 새로 만들어도 잃을 것이 없다.
    absent,
    /// 읽었다.
    known: Known,
};

pub const Intent = enum {
    /// 켜져 있다 — 없으면 넣고, 낡았으면 고친다.
    ensure,
    /// 사용자가 **명시적으로** 제거를 요청했다. 게이트를 끈 것만으로는 여기 오지 않는다(§5 — 끔은
    /// «설치하지 않음» 이고 «제거» 가 아니다. 인스턴스 둘이 서로 다른 값을 가지면 설치·제거가 왕복한다).
    uninstall,
};

pub const Plan = enum {
    /// 아무것도 하지 않는다.
    leave,
    /// 우리 항목을 새로 넣는다.
    install,
    /// 우리 항목을 걷어 내고 다시 넣는다(낡았거나 일부만 있다).
    ///
    /// **한 번의 쓰기로 끝낸다.** 걷어 내기와 넣기를 두 번에 나눠 쓰면 그 사이에 죽었을 때 사용자에게
    /// «훅이 사라진» 파일이 남는다. platform 은 트리를 메모리에서 다 고친 뒤 atomic 하게 한 번 쓴다.
    refresh,
    /// 우리 항목을 걷어 낸다.
    remove,
    /// 상태를 모른다 — **손대지 않는다**.
    abort,
};

/// `want_events` 는 계약 §2 세트의 이벤트 수다(`agent_hook_command.claude_events.len`).
pub fn planFor(state: State, intent: Intent, want_events: usize) Plan {
    switch (state) {
        // **모르는 상태는 건드리지 않는다.** 지우는 쪽도 마찬가지다 — 무엇을 지우는지 모르는 채로 쓰면
        // 사용자 항목을 함께 날린다.
        .unreadable => return .abort,
        .absent => return switch (intent) {
            .ensure => .install,
            // 없는 파일에서 지울 것은 없다. 파일을 만들지도 않는다(남의 홈에 흔적을 남기지 않는다).
            .uninstall => .leave,
        },
        .known => |k| switch (intent) {
            .uninstall => return if (k.ours > 0) .remove else .leave,
            .ensure => {
                if (k.ours == 0) return .install;
                // 하나라도 낡았거나 덮지 못한 이벤트가 있으면 **전부 걷어 내고 다시 넣는다**. 부분 갱신은
                // 순서·중복을 다루는 분기를 늘리는데, 우리 항목은 언제나 같은 모양이라 얻는 것이 없다.
                if (k.ours_current != k.ours) return .refresh;
                if (k.events_covered != want_events) return .refresh;
                // 세트에서 뺀 이벤트에 우리 항목이 남아 있으면 개수만으로는 «다 덮었다» 로 보인다.
                if (k.events_outside != 0) return .refresh;
                // **우리 항목이 세트보다 많으면 중복이다.** 위 셋을 다 통과하고도 이 수가 어긋나는 경우가 있다 —
                // 한 이벤트에 우리 표식이 둘 붙은 상태(사용자가 커맨드를 복사했거나 옛 항목이 남았다)는
                // `events_covered` 가 «덮었다» 로 세므로 앞의 검사에 걸리지 않는다. 그러면 그 중복은 영영
                // 안 지워지고 **이벤트마다 훅이 두 번 돈다**(로그 줄도 두 배가 된다).
                if (k.ours != want_events) return .refresh;
                return .leave;
            },
        },
    }
}

/// 그 provider 의 세트로 판정한다. **호출자가 세트 «크기» 를 넘기지 않는다** — 그 값이 어긋나면 «다
/// 덮었다» 를 잘못 판정하는데, 세트는 이 저장소 안의 상수라 넘겨받을 이유가 없다. `planFor` 의 인자는
/// 테스트가 다른 크기를 넣어 경계를 보기 위한 것이다.
///
/// **provider 는 넘겨받는다** — 세트가 그것으로 갈리기 때문이다(codex 에는 `Notification` 이 없다).
pub fn planForSet(provider: command.Provider, state: State, intent: Intent) Plan {
    return planFor(state, intent, command.eventsFor(provider, .local).len);
}

/// 이 계획이 사용자 파일을 **바꾸는가**. platform 이 락·백업·atomic write 를 준비할지 정하는 데 쓴다.
pub fn mutates(plan: Plan) bool {
    return switch (plan) {
        .install, .refresh, .remove => true,
        .leave, .abort => false,
    };
}

// ── Claude `settings.json` 트리 수술 ────────────────────────────────────────────────────────────
//
// **왜 여기(순수 층)인가**: 이 코드가 틀리면 사용자 홈의 JSON 이 상한다. platform 에 두면 파일과 GUI 가
// 있어야만 돌아가 분기를 전수로 못 본다. `std.json.Value` 트리는 I/O 가 아니므로 여기서 다룰 수 있고,
// platform 은 «읽기 → 이 함수들 → atomic write» 만 한다.
//
// 다루는 모양(claude 계약):
//
//     { "hooks": { "<이벤트>": [ { "matcher"?: "…", "hooks": [ { "type": "command", "command": "…",
//                                                                "timeout": N } ] } ] } }
//
// **사용자 항목은 순서까지 보존한다**(계약 §5) — 우리 항목만 골라 빼고, 우리 것은 배열 끝에 붙인다.

/// 우리 항목이 **지금 만들 것과 같은가**. 세 값이 모두 맞아야 «최신» 이다.
///
/// 커맨드 바이트만 보면 **matcher 나 timeout 이 어긋난 항목이 최신으로 통과한다** — matcher 가 빠진
/// `PreToolUse` 는 provider 가 언제 부를지 우리가 정한 바와 달라지고, `timeout` 이 없으면 provider 기본값에
/// 끌려간다(계약 §4.1 이 «기본값에 맡기지 않는다» 고 정한 그 값이다).
fn entryIsCurrent(
    entry: std.json.ObjectMap,
    want_command: []const u8,
    want_matcher: ?[]const u8,
    group: std.json.ObjectMap,
) bool {
    const cmd = switch (entry.get("command") orelse return false) {
        .string => |s| s,
        else => return false,
    };
    if (!std.mem.eql(u8, cmd, want_command)) return false;
    const timeout_ok = switch (entry.get("timeout") orelse std.json.Value{ .null = {} }) {
        .integer => |n| n == @as(i64, command.timeout_seconds),
        else => false,
    };
    if (!timeout_ok) return false;
    const have_matcher: ?[]const u8 = switch (group.get("matcher") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
    if (want_matcher) |want| {
        return have_matcher != null and std.mem.eql(u8, have_matcher.?, want);
    }
    return have_matcher == null;
}

/// 그 provider 의 세트에서 이 이벤트를 찾는다(없으면 «세트 밖»).
fn setEventIndex(provider: command.Provider, name: []const u8) ?usize {
    for (command.eventsFor(provider, .local), 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// `settings.json` 의 `hooks` 값을 훑어 우리 항목을 센다. `hooks_value` 가 `null` 이면 그 키가 없는 것이다
/// (읽지 못한 것이 아니다 — 그 구분은 platform 이 파일 층에서 한다).
///
/// **모양을 모르면 `null` 을 돌려준다.** 배열이어야 할 자리에 문자열이 있는 파일은 우리가 아는 파일이 아니고,
/// 거기에 쓰면 사용자 설정을 우리 해석대로 뭉갠다. 호출자는 이것을 `State.unreadable` 로 접어 손대지 않는다.
pub fn scan(provider: command.Provider, hooks_value: ?std.json.Value, want_command: []const u8) ?Known {
    var known: Known = .{};
    const hooks = switch (hooks_value orelse return known) {
        .object => |o| o,
        // 키는 있는데 객체가 아니다 — 우리가 아는 모양이 아니다.
        else => return null,
    };
    const set = command.eventsFor(provider, .local);
    // 세트 크기는 provider 마다 다르므로 최대치로 잡고 앞부분만 쓴다(순수 층이라 할당하지 않는다).
    var covered = [_]bool{false} ** max_events;
    for (hooks.keys(), hooks.values()) |name, groups_value| {
        const groups = switch (groups_value) {
            .array => |arr| arr,
            else => return null,
        };
        const set_index = setEventIndex(provider, name);
        const want_matcher: ?[]const u8 = if (set_index) |i| set[i].matcher else null;
        for (groups.items) |group_value| {
            const group = switch (group_value) {
                .object => |o| o,
                else => return null,
            };
            const entries = switch (group.get("hooks") orelse continue) {
                .array => |arr| arr,
                else => return null,
            };
            for (entries.items) |entry_value| {
                const entry = switch (entry_value) {
                    .object => |o| o,
                    else => return null,
                };
                const cmd = switch (entry.get("command") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                if (command.isLegacy(cmd)) known.legacy_present = true;
                if (!command.isOurs(cmd)) continue;
                known.ours += 1;
                if (set_index) |i| {
                    covered[i] = true;
                    if (entryIsCurrent(entry, want_command, want_matcher, group)) known.ours_current += 1;
                } else {
                    // 세트 밖에 남은 우리 항목. 개수만 비교하면 «다 덮었다» 로 보여 영영 안 지워진다.
                    known.events_outside += 1;
                }
            }
        }
    }
    for (covered[0..set.len]) |c| {
        if (c) known.events_covered += 1;
    }
    return known;
}

/// 우리 항목이 트리의 **어디에** 놓였는가. codex 의 신뢰 키가 `<경로>:<이벤트>:<그룹>:<핸들러>` 로
/// **위치 인덱스**를 담기 때문에 필요하다 — 그 값을 추측하면(예: 「우리 것은 늘 마지막이니 len-1」)
/// 사용자 항목이 뒤에 붙는 순간 조용히 어긋나고, 증상은 「그 훅만 신뢰되지 않음」이라 찾기 어렵다.
pub const Placement = struct {
    json_name: []const u8,
    group_index: usize,
    handler_index: usize,
};

/// 트리를 훑어 우리 항목의 자리를 채운다. 담을 수 있는 만큼만 채우고 **찾은 총 개수**를 돌려준다
/// (넘치면 호출자가 그 사실을 안다 — 조용히 자르지 않는다).
pub fn ourPlacements(hooks_value: ?std.json.Value, want_command: []const u8, out: []Placement) usize {
    _ = want_command; // 표식으로 고른다 — 경로·상한이 달라도 우리 것이다(`isOurs` 와 같은 규율)
    var found: usize = 0;
    const hooks = switch (hooks_value orelse return 0) {
        .object => |o| o,
        else => return 0,
    };
    for (hooks.keys(), hooks.values()) |name, groups_value| {
        const groups = switch (groups_value) {
            .array => |arr| arr,
            else => continue,
        };
        for (groups.items, 0..) |group_value, gi| {
            const group = switch (group_value) {
                .object => |o| o,
                else => continue,
            };
            const entries = switch (group.get("hooks") orelse continue) {
                .array => |arr| arr,
                else => continue,
            };
            for (entries.items, 0..) |entry_value, hi| {
                const entry = switch (entry_value) {
                    .object => |o| o,
                    else => continue,
                };
                const cmd = switch (entry.get("command") orelse continue) {
                    .string => |x| x,
                    else => continue,
                };
                if (!command.isOurs(cmd)) continue;
                if (found < out.len) out[found] = .{ .json_name = name, .group_index = gi, .handler_index = hi };
                found += 1;
            }
        }
    }
    return found;
}

pub const ApplyError = error{ OutOfMemory, Unrecognized };

/// 우리 표식이 붙은 항목을 **전부** 걷어 낸다. 비게 된 group·이벤트 키는 함께 지운다 — 남겨 두면 사용자
/// 파일에 빈 껍데기가 쌓인다. 사용자 항목과 과거 표식 항목은 순서 그대로 남는다(P1).
fn stripOurs(a: std.mem.Allocator, hooks: *std.json.ObjectMap) ApplyError!void {
    var empty_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer empty_keys.deinit(a);

    for (hooks.keys(), hooks.values()) |name, *groups_value| {
        const groups: *std.json.Array = switch (groups_value.*) {
            .array => |*arr| arr,
            else => return error.Unrecognized,
        };
        var gi: usize = 0;
        while (gi < groups.items.len) {
            const group: *std.json.ObjectMap = switch (groups.items[gi]) {
                .object => |*o| o,
                else => return error.Unrecognized,
            };
            if (group.getPtr("hooks")) |entries_value| {
                const entries: *std.json.Array = switch (entries_value.*) {
                    .array => |*arr| arr,
                    else => return error.Unrecognized,
                };
                var ei: usize = 0;
                while (ei < entries.items.len) {
                    const is_ours = switch (entries.items[ei]) {
                        .object => |o| blk: {
                            const cmd = switch (o.get("command") orelse break :blk false) {
                                .string => |s| s,
                                else => break :blk false,
                            };
                            break :blk command.isOurs(cmd);
                        },
                        else => return error.Unrecognized,
                    };
                    if (is_ours) {
                        _ = entries.orderedRemove(ei); // 순서 보존이 계약이라 swapRemove 를 쓰지 않는다
                    } else {
                        ei += 1;
                    }
                }
                // **우리 항목만 있던 group 은 통째로 지운다.** `matcher` 만 남은 껍데기가 쌓이면 사용자가
                // 자기 파일에서 우리 흔적을 계속 보게 된다.
                if (entries.items.len == 0) {
                    _ = groups.orderedRemove(gi);
                    continue;
                }
            }
            gi += 1;
        }
        if (groups.items.len == 0) try empty_keys.append(a, name);
    }
    // 순회 중에 키를 지우면 인덱스가 어긋난다 — 다 돈 뒤에 지운다.
    for (empty_keys.items) |name| _ = hooks.orderedRemove(name);
}

/// 세트대로 우리 항목을 **배열 끝에** 붙인다. 사용자 항목이 앞에 그대로 남는다.
fn appendOurs(provider: command.Provider, a: std.mem.Allocator, hooks: *std.json.ObjectMap, want_command: []const u8) ApplyError!void {
    for (command.eventsFor(provider, .local)) |e| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(a, "type", .{ .string = "command" });
        try entry.put(a, "command", .{ .string = want_command });
        try entry.put(a, "timeout", .{ .integer = @as(i64, command.timeout_seconds) });

        var entries: std.json.Array = .init(a);
        try entries.append(.{ .object = entry });

        var group: std.json.ObjectMap = .empty;
        if (e.matcher) |m| try group.put(a, "matcher", .{ .string = m });
        try group.put(a, "hooks", .{ .array = entries });

        if (hooks.getPtr(e.name)) |groups_value| {
            const groups: *std.json.Array = switch (groups_value.*) {
                .array => |*arr| arr,
                else => return error.Unrecognized,
            };
            try groups.append(.{ .object = group });
        } else {
            var groups: std.json.Array = .init(a);
            try groups.append(.{ .object = group });
            try hooks.put(a, e.name, .{ .array = groups });
        }
    }
}

pub const Mode = enum { install, remove };

/// 계획을 트리에 적용한다. `install` 은 «걷어 내고 다시 넣기» 라 `install`·`refresh` 를 함께 처리한다 —
/// 계약이 요구하는 **한 번의 쓰기**가 이렇게 성립한다(중간 상태가 파일에 닿지 않는다).
///
/// 적용 뒤 `hooks` 가 비면 호출자가 그 키를 지운다(빈 객체를 남기지 않는다).
pub fn apply(provider: command.Provider, a: std.mem.Allocator, hooks: *std.json.ObjectMap, want_command: []const u8, mode: Mode) ApplyError!void {
    try stripOurs(a, hooks);
    if (mode == .install) try appendOurs(provider, a, hooks, want_command);
}

const testing = std.testing;

test "읽지 못한 파일은 어느 방향으로도 손대지 않는다" {
    // 같은 계열의 선례가 겪은 사고: 읽기 실패를 «빈 설정» 으로 접어 사용자 파일을 통째로 날렸다.
    // 지우는 쪽도 막는다 — 무엇을 지우는지 모르는 채로 쓰면 사용자 항목이 함께 사라진다.
    try testing.expectEqual(Plan.abort, planFor(.unreadable, .ensure, 6));
    try testing.expectEqual(Plan.abort, planFor(.unreadable, .uninstall, 6));
    try testing.expect(!mutates(.abort));
}

test "없는 파일은 켤 때만 만든다" {
    try testing.expectEqual(Plan.install, planFor(.absent, .ensure, 6));
    // 끄는 사람의 홈에 파일을 만들지 않는다.
    try testing.expectEqual(Plan.leave, planFor(.absent, .uninstall, 6));
}

test "우리 항목이 없으면 넣는다" {
    const empty: State = .{ .known = .{} };
    try testing.expectEqual(Plan.install, planFor(empty, .ensure, 6));
    // 사용자 항목만 있는 파일도 마찬가지다 — 그 항목은 세지 않으므로 `ours` 가 0 이다.
    const user_only: State = .{ .known = .{ .ours = 0, .legacy_present = false } };
    try testing.expectEqual(Plan.install, planFor(user_only, .ensure, 6));
}

test "완전히 설치돼 있으면 그대로 둔다" {
    const full: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(Plan.leave, planFor(full, .ensure, 6));
    try testing.expect(!mutates(.leave));
}

test "낡은 커맨드가 하나라도 있으면 전부 다시 넣는다" {
    // 경로·상한·표식이 바뀌면 `ours_current` 가 준다. 부분 갱신은 순서·중복 분기를 늘리기만 한다.
    const stale: State = .{ .known = .{ .ours = 6, .ours_current = 5, .events_covered = 6 } };
    try testing.expectEqual(Plan.refresh, planFor(stale, .ensure, 6));
}

test "일부 이벤트만 덮고 있으면 다시 넣는다" {
    // 사용자가 항목 하나를 지웠거나, 우리가 세트를 늘린 뒤다. 둘 다 «덮지 못한 이벤트» 로 나타난다.
    const partial: State = .{ .known = .{ .ours = 4, .ours_current = 4, .events_covered = 4 } };
    try testing.expectEqual(Plan.refresh, planFor(partial, .ensure, 6));
}

test "명시적 제거만 지운다 — 게이트를 끈 것으로는 지우지 않는다" {
    // §5: 끔은 «설치하지 않음» 이다. 인스턴스 둘이 서로 다른 게이트 값을 가지면 설치·제거가 무한히 왕복한다.
    const installed: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(Plan.remove, planFor(installed, .uninstall, 6));
    const none: State = .{ .known = .{} };
    try testing.expectEqual(Plan.leave, planFor(none, .uninstall, 6));
}

test "과거 표식이 있어도 계획이 달라지지 않는다 — 그 항목은 건드리지 않는다" {
    // P1 이 «legacy 잔재를 자동 정리하지 않는다» 고 정했다. 그 존재가 우리 판정을 바꾸면 그 규칙이 샌다.
    const with_legacy: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6, .legacy_present = true } };
    const without: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(planFor(without, .ensure, 6), planFor(with_legacy, .ensure, 6));
    try testing.expectEqual(planFor(without, .uninstall, 6), planFor(with_legacy, .uninstall, 6));
}

test "바꾸는 계획만 락·백업을 요구한다" {
    try testing.expect(mutates(.install));
    try testing.expect(mutates(.refresh));
    try testing.expect(mutates(.remove));
    try testing.expect(!mutates(.leave));
    try testing.expect(!mutates(.abort));
}

test "세트에서 뺀 이벤트에 남은 우리 항목을 걷어 낸다" {
    // 개수만 비교하면 «세트 6개를 다 덮었다» 로 보여 그 항목이 영영 안 지워진다. 실제로 세트에서
    // `PostToolUse` 를 뺀 적이 있으므로(계약 §3.1) 가상의 상황이 아니다.
    const leftover: State = .{
        .known = .{
            .ours = 7,
            .ours_current = 7,
            .events_covered = 6, // 세트의 6개는 다 덮었지만
            .events_outside = 1, // 세트 밖 이벤트에 하나가 더 남아 있다
        },
    };
    try testing.expectEqual(Plan.refresh, planFor(leftover, .ensure, 6));

    // 그 하나가 없으면 그대로 둔다 — 이 대조가 «세트 밖 항목 때문» 임을 증명한다.
    const clean: State = .{ .known = .{ .ours = 6, .ours_current = 6, .events_covered = 6 } };
    try testing.expectEqual(Plan.leave, planFor(clean, .ensure, 6));
}

test "우리 항목이 세트보다 많으면 중복이다 — 훅이 두 번 돈다" {
    // 한 이벤트에 우리 표식이 둘 붙으면 `events_covered` 는 그것을 «덮었다» 로 세므로 앞의 검사가 다 통과한다.
    const dup: State = .{ .known = .{
        .ours = 7,
        .ours_current = 7,
        .events_covered = 6,
        .events_outside = 0,
    } };
    try testing.expectEqual(Plan.refresh, planFor(dup, .ensure, 6));

    // 대조: 하나 적은 쪽은 애초에 `events_covered` 로 걸린다(이 검사가 «많은 쪽» 전용임을 보인다).
    const missing: State = .{ .known = .{ .ours = 5, .ours_current = 5, .events_covered = 5 } };
    try testing.expectEqual(Plan.refresh, planFor(missing, .ensure, 6));
}

test "세트 크기는 호출자가 넘기지 않는다" {
    // 호출자가 그 수를 넘기면 어긋난 값이 «다 덮었다» 를 잘못 판정한다. 세트는 저장소 안의 상수다.
    const full: State = .{ .known = .{
        .ours = command.claude_events.len,
        .ours_current = command.claude_events.len,
        .events_covered = command.claude_events.len,
    } };
    try testing.expectEqual(Plan.leave, planForSet(.claude, full, .ensure));
    try testing.expectEqual(Plan.remove, planForSet(.claude, full, .uninstall));
}

test "Known 의 필드가 늘면 판정 누락을 잡는다" {
    // 필드를 더하고 판정에 안 넣으면 **조용히 무시**된다. 개수로 못 박아 그 드리프트를 컴파일이 아니라
    // 테스트에서 잡는다 — 새 필드를 넣는 사람이 여기서 «이 필드는 판정에 어떻게 쓰이나» 를 묻게 된다.
    const fields = @typeInfo(Known).@"struct".fields;
    try testing.expectEqual(@as(usize, 5), fields.len);

    // 각 필드가 실제로 계획을 움직이는지(또는 의도적으로 안 움직이는지) 하나씩 흔들어 본다.
    const base: Known = .{
        .ours = command.claude_events.len,
        .ours_current = command.claude_events.len,
        .events_covered = command.claude_events.len,
    };
    try testing.expectEqual(Plan.leave, planForSet(.claude, .{ .known = base }, .ensure));

    var no_ours = base;
    no_ours.ours = 0;
    try testing.expectEqual(Plan.install, planForSet(.claude, .{ .known = no_ours }, .ensure));

    var stale = base;
    stale.ours_current -= 1;
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = stale }, .ensure));

    var partial = base;
    partial.events_covered -= 1;
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = partial }, .ensure));

    var outside = base;
    outside.events_outside = 1;
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = outside }, .ensure));

    // `legacy_present` 는 **의도적으로** 계획을 바꾸지 않는다(P1 — 자동 정리 금지).
    var legacy = base;
    legacy.legacy_present = true;
    try testing.expectEqual(Plan.leave, planForSet(.claude, .{ .known = legacy }, .ensure));
}

// ── 트리 수술 테스트 ────────────────────────────────────────────────────────────────────────────
//
// 여기서 지키는 것은 하나다: **사용자 파일을 우리가 아는 만큼만 고친다.** 그래서 «우리 항목이 들어갔나»
// 보다 «남의 것이 그대로인가» 를 더 많이 본다.

/// 지금 세트로 만드는 커맨드(테스트 로그 디렉터리 기준).
fn wantCommand(a: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try command.build(&out, a, "claude", "/tmp/maru-hooks");
    return out.toOwnedSlice(a);
}

/// `settings.json` 한 벌에 계획을 적용하고 다시 문자열로 만든다. platform 이 하는 일과 같은 순서다 —
/// 읽고, `hooks` 만 고치고, 비면 그 키를 지운다.
fn runClaude(a: std.mem.Allocator, json_text: []const u8, want_command: []const u8, mode: Mode) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    var root = switch (parsed.value) {
        .object => |o| o,
        else => return error.Unrecognized,
    };
    var hooks: std.json.ObjectMap = switch (root.get("hooks") orelse std.json.Value{ .object = .empty }) {
        .object => |o| o,
        else => return error.Unrecognized,
    };
    try apply(.claude, a, &hooks, want_command, mode);
    if (hooks.count() == 0) {
        _ = root.orderedRemove("hooks");
    } else {
        try root.put(a, "hooks", .{ .object = hooks });
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(a, &out);
    try std.json.Stringify.value(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }, &aw.writer);
    out = aw.toArrayList();
    return out.toOwnedSlice(a);
}

/// 문자열이 된 결과를 다시 훑는다 — 「쓴 것을 다시 읽어 같은 판정이 나오는가」가 멱등성의 정의다.
fn scanText(a: std.mem.Allocator, json_text: []const u8, want_command: []const u8) !?Known {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.Unrecognized,
    };
    return scan(.claude, root.get("hooks"), want_command);
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "빈 설정에 넣으면 세트 전체가 최신으로 선다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    const before = try scanText(a, "{}", want);
    try testing.expectEqual(Known{}, before.?);
    try testing.expectEqual(Plan.install, planForSet(.claude, .{ .known = before.? }, .ensure));

    const after_text = try runClaude(a, "{}", want, .install);
    const after = (try scanText(a, after_text, want)).?;
    try testing.expectEqual(@as(usize, command.claude_events.len), after.ours);
    try testing.expectEqual(@as(usize, command.claude_events.len), after.ours_current);
    try testing.expectEqual(@as(usize, command.claude_events.len), after.events_covered);
    try testing.expectEqual(@as(usize, 0), after.events_outside);
    // **쓴 것을 다시 읽었을 때 «할 일 없음» 이 나와야** 매 시작마다 사용자 파일을 다시 쓰지 않는다.
    try testing.expectEqual(Plan.leave, planForSet(.claude, .{ .known = after }, .ensure));
}

test "다시 넣어도 항목이 늘지 않는다 — 멱등" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    const once = try runClaude(a, "{}", want, .install);
    const twice = try runClaude(a, once, want, .install);
    // 바이트까지 같아야 한다. 개수만 보면 순서가 흔들리는 것을 놓친다.
    try testing.expectEqualStrings(once, twice);
}

test "사용자 항목은 내용도 순서도 그대로 남는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    const user =
        \\{
        \\  "model": "opus",
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "my-guard.sh" } ] },
        \\      { "matcher": "*", "hooks": [ { "type": "command", "command": "audit.sh" } ] }
        \\    ]
        \\  }
        \\}
    ;
    const after = try runClaude(a, user, want, .install);
    // 사용자 항목 둘이 **그 순서로** 남는다.
    const guard = std.mem.indexOf(u8, after, "my-guard.sh") orelse return error.TestUnexpectedResult;
    const audit = std.mem.indexOf(u8, after, "audit.sh") orelse return error.TestUnexpectedResult;
    try testing.expect(guard < audit);
    // 우리 것은 뒤에 붙는다 — 앞에 끼워 넣으면 사용자가 정한 실행 순서를 바꾼다.
    const ours = std.mem.indexOf(u8, after, command.marker) orelse return error.TestUnexpectedResult;
    try testing.expect(audit < ours);
    // `hooks` 밖의 키도 손대지 않는다.
    try testing.expect(std.mem.indexOf(u8, after, "\"model\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "opus") != null);

    // 제거하면 사용자 항목만 남는다(설치 전 모양으로 돌아간다).
    const removed = try runClaude(a, after, want, .remove);
    try testing.expect(std.mem.indexOf(u8, removed, command.marker) == null);
    try testing.expect(std.mem.indexOf(u8, removed, "my-guard.sh") != null);
    try testing.expect(std.mem.indexOf(u8, removed, "audit.sh") != null);
    try testing.expectEqual(@as(usize, 0), (try scanText(a, removed, want)).?.ours);
}

test "우리 것만 있던 자리는 빈 껍데기를 남기지 않는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    const installed = try runClaude(a, "{}", want, .install);
    const removed = try runClaude(a, installed, want, .remove);
    // `hooks` 키까지 사라져야 한다 — `"hooks": {}` 가 남으면 사용자는 우리가 뭔가 남긴 것으로 읽는다.
    try testing.expect(std.mem.indexOf(u8, removed, "\"hooks\"") == null);
    try testing.expect(std.mem.indexOf(u8, removed, "PreToolUse") == null);
}

test "낡은 커맨드는 걷어 내고 다시 넣는다 — 한 벌만 남는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    // 경로가 달랐던 시절의 우리 항목(표식은 같다).
    var stale_out: std.ArrayListUnmanaged(u8) = .empty;
    try command.build(&stale_out, a, "claude", "/tmp/maru-hooks-old");
    const stale = try stale_out.toOwnedSlice(a);

    const text = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "Stop": [ {{ "hooks": [ {{ "type": "command", "command": {f}, "timeout": 2 }} ] }} ] }} }}
    , .{std.json.fmt(std.json.Value{ .string = stale }, .{})});

    const before = (try scanText(a, text, want)).?;
    try testing.expectEqual(@as(usize, 1), before.ours);
    try testing.expectEqual(@as(usize, 0), before.ours_current); // 커맨드가 다르다
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = before }, .ensure));

    const after_text = try runClaude(a, text, want, .install);
    try testing.expect(std.mem.indexOf(u8, after_text, "maru-hooks-old") == null); // 낡은 것이 남지 않는다
    const after = (try scanText(a, after_text, want)).?;
    try testing.expectEqual(@as(usize, command.claude_events.len), after.ours); // 두 벌이 되지 않는다
    try testing.expectEqual(Plan.leave, planForSet(.claude, .{ .known = after }, .ensure));
}

test "matcher 나 timeout 이 어긋난 항목은 최신이 아니다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);
    const cmd = std.json.fmt(std.json.Value{ .string = want }, .{});

    // 커맨드 바이트는 같은데 `timeout` 이 없다 — provider 기본값에 끌려간다(계약 §4.1).
    const no_timeout = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "Stop": [ {{ "hooks": [ {{ "type": "command", "command": {f} }} ] }} ] }} }}
    , .{cmd});
    const s1 = (try scanText(a, no_timeout, want)).?;
    try testing.expectEqual(@as(usize, 1), s1.ours);
    try testing.expectEqual(@as(usize, 0), s1.ours_current);

    // `PreToolUse` 는 세트가 matcher `*` 를 요구하는데 그것이 빠졌다.
    const no_matcher = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "PreToolUse": [ {{ "hooks": [ {{ "type": "command", "command": {f}, "timeout": 2 }} ] }} ] }} }}
    , .{cmd});
    const s2 = (try scanText(a, no_matcher, want)).?;
    try testing.expectEqual(@as(usize, 1), s2.ours);
    try testing.expectEqual(@as(usize, 0), s2.ours_current);
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = s2 }, .ensure));

    // 대조: 셋 다 맞으면 최신이다(위 둘이 «커맨드가 달라서» 걸린 것이 아님을 증명한다).
    const ok = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "PreToolUse": [ {{ "matcher": "*", "hooks": [ {{ "type": "command", "command": {f}, "timeout": 2 }} ] }} ] }} }}
    , .{cmd});
    const s3 = (try scanText(a, ok, want)).?;
    try testing.expectEqual(@as(usize, 1), s3.ours_current);
}

test "세트 밖 이벤트에 남은 우리 항목을 걷어 낸다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);
    const cmd = std.json.fmt(std.json.Value{ .string = want }, .{});

    // `PostToolUse` 는 세트에서 뺐다(계약 §3.1). 그때 설치된 항목이 남아 있는 상황이다.
    const text = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "PostToolUse": [ {{ "matcher": "*", "hooks": [ {{ "type": "command", "command": {f}, "timeout": 2 }} ] }} ] }} }}
    , .{cmd});
    const before = (try scanText(a, text, want)).?;
    try testing.expectEqual(@as(usize, 1), before.events_outside);
    try testing.expectEqual(@as(usize, 0), before.events_covered);
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = before }, .ensure));

    const after_text = try runClaude(a, text, want, .install);
    try testing.expect(std.mem.indexOf(u8, after_text, "PostToolUse") == null);
    try testing.expectEqual(@as(usize, 0), (try scanText(a, after_text, want)).?.events_outside);
}

test "같은 이벤트에 우리 항목이 둘이면 하나로 줄인다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);
    const cmd = std.json.fmt(std.json.Value{ .string = want }, .{});

    // 사용자가 커맨드를 복사했거나(표식이 «복사하지 말라» 고 적힌 이유다) 옛 항목이 남은 상태.
    const text = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "Stop": [
        \\  {{ "hooks": [ {{ "type": "command", "command": {f}, "timeout": 2 }} ] }},
        \\  {{ "hooks": [ {{ "type": "command", "command": {f}, "timeout": 2 }} ] }}
        \\] }} }}
    , .{ cmd, cmd });
    const before = (try scanText(a, text, want)).?;
    try testing.expectEqual(@as(usize, 2), before.ours);
    try testing.expectEqual(@as(usize, 1), before.events_covered); // «덮었다» 로 세어 앞 검사를 통과한다
    try testing.expectEqual(Plan.refresh, planForSet(.claude, .{ .known = before }, .ensure));

    const after_text = try runClaude(a, text, want, .install);
    const after = (try scanText(a, after_text, want)).?;
    try testing.expectEqual(@as(usize, command.claude_events.len), after.ours); // 한 벌만 남는다
    try testing.expectEqual(Plan.leave, planForSet(.claude, .{ .known = after }, .ensure));
}

test "과거 표식 항목은 세되 건드리지 않는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    // P1: legacy 잔재를 자동 정리하지 않는다. 설치·제거 어느 쪽으로도 살아남아야 한다.
    const legacy_cmd = "echo legacy # " ++ command.legacy_markers[0];
    const text = try std.fmt.allocPrint(a,
        \\{{ "hooks": {{ "Stop": [ {{ "hooks": [ {{ "type": "command", "command": {f} }} ] }} ] }} }}
    , .{std.json.fmt(std.json.Value{ .string = legacy_cmd }, .{})});

    const before = (try scanText(a, text, want)).?;
    try testing.expect(before.legacy_present);
    try testing.expectEqual(@as(usize, 0), before.ours); // 우리 것으로 세지 않는다

    const installed = try runClaude(a, text, want, .install);
    try testing.expect(std.mem.indexOf(u8, installed, legacy_cmd) != null);
    const removed = try runClaude(a, installed, want, .remove);
    try testing.expect(std.mem.indexOf(u8, removed, legacy_cmd) != null);
    try testing.expect(std.mem.indexOf(u8, removed, command.marker) == null);
}

test "codex 세트로 넣으면 Notification 이 들어가지 않는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    // 같은 함수에 provider 만 바꿔 넣는다 — 파일 모양이 같으므로(실측) 코드가 갈릴 이유가 없다.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    var root_obj = parsed.value.object;
    var hooks: std.json.ObjectMap = .empty;
    try apply(.codex, a, &hooks, want, .install);
    try root_obj.put(a, "hooks", .{ .object = hooks });

    try testing.expectEqual(@as(usize, command.codex_events.len), hooks.count());
    try testing.expect(hooks.get("Notification") == null); // codex 에 없는 이벤트다
    try testing.expect(hooks.get("SessionStart") != null);

    const known = scan(.codex, root_obj.get("hooks"), want).?;
    try testing.expectEqual(@as(usize, command.codex_events.len), known.ours);
    try testing.expectEqual(@as(usize, command.codex_events.len), known.events_covered);
    try testing.expectEqual(@as(usize, 0), known.events_outside);
    try testing.expectEqual(Plan.leave, planForSet(.codex, .{ .known = known }, .ensure));
}

test "provider 를 바꿔 보면 남은 항목이 세트 밖으로 잡힌다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    // claude 세트로 넣은 파일을 codex 세트로 훑으면 claude 에만 있는 이벤트가 «세트 밖» 이다.
    // 이 대조가 **세트 분리가 실제로 판정을 바꾼다**는 것을 보인다 — 안 그러면 분리가 장식이다.
    var hooks: std.json.ObjectMap = .empty;
    try apply(.claude, a, &hooks, want, .install);
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(a, "hooks", .{ .object = hooks });

    // 기대치를 손으로 적지 않는다 — 세트가 달라질 때마다 여기를 고치게 되고, 그러면 이 테스트가
    // «분리가 판정을 바꾼다» 대신 «내가 최근에 무엇을 더했나» 를 재게 된다.
    const claude_only = comptime blk: {
        var n: usize = 0;
        for (command.claude_events) |c| {
            var in_codex = false;
            for (command.codex_events) |x| {
                if (std.mem.eql(u8, c.name, x.name)) in_codex = true;
            }
            if (!in_codex) n += 1;
        }
        break :blk n;
    };
    try testing.expect(claude_only > 0); // 대조가 성립하는 전제
    const as_codex = scan(.codex, wrapper.get("hooks"), want).?;
    try testing.expectEqual(claude_only, as_codex.events_outside);
    try testing.expectEqual(Plan.refresh, planForSet(.codex, .{ .known = as_codex }, .ensure));

    const as_claude = scan(.claude, wrapper.get("hooks"), want).?;
    try testing.expectEqual(@as(usize, 0), as_claude.events_outside);
    try testing.expectEqual(Plan.leave, planForSet(.claude, .{ .known = as_claude }, .ensure));
}

test "고정 배열 상한이 세트를 따라온다" {
    // `scan`·`ourPlacements` 는 순수 층이라 할당하지 않고 고정 배열로 «덮은 이벤트» 를 센다. 그 상한을
    // 손으로 적으면 이벤트를 더할 때 잊고 범위를 넘긴다 — 그래서 세트에서 뽑는다. 여기서는 그 유도가
    // **두 provider 를 다 덮는지** 만 확인한다.
    try testing.expect(command.claude_events.len <= max_events);
    try testing.expect(command.codex_events.len <= max_events);
    try testing.expect(max_events == command.claude_events.len or max_events == command.codex_events.len);
}

test "모르는 모양이면 판정을 포기한다 — 거기에 쓰면 사용자 설정을 뭉갠다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    // `hooks` 가 객체가 아니다 / 이벤트 값이 배열이 아니다 / group 이 객체가 아니다.
    for ([_][]const u8{
        \\{ "hooks": "off" }
        ,
        \\{ "hooks": { "Stop": 3 } }
        ,
        \\{ "hooks": { "Stop": [ 3 ] } }
        ,
        \\{ "hooks": { "Stop": [ { "hooks": "no" } ] } }
        ,
    }) |text| {
        try testing.expectEqual(@as(?Known, null), try scanText(a, text, want));
    }
    // 호출자는 이것을 `unreadable` 로 접고, 그 계획은 `abort` 다.
    try testing.expectEqual(Plan.abort, planForSet(.claude, .unreadable, .ensure));
}

test "우리 항목의 자리를 정확히 집는다 — 신뢰 키가 그 인덱스를 담는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);

    // 사용자 항목이 **앞에** 둘 있는 이벤트를 만든다. 우리 것은 그 뒤에 붙으므로 group_index 가 2 다.
    const user =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "a.sh" } ] },
        \\      { "matcher": "*", "hooks": [ { "type": "command", "command": "b.sh" } ] }
        \\    ]
        \\  }
        \\}
    ;
    const after_text = try runClaude(a, user, want, .install);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, after_text, .{});
    const root_obj = parsed.value.object;

    var slots: [max_events]Placement = undefined;
    const n = ourPlacements(root_obj.get("hooks"), want, &slots);
    try testing.expectEqual(@as(usize, command.claude_events.len), n);

    var seen_pre = false;
    for (slots[0..n]) |pl| {
        try testing.expectEqual(@as(usize, 0), pl.handler_index); // 우리 group 에는 항목이 하나뿐이다
        if (std.mem.eql(u8, pl.json_name, "PreToolUse")) {
            seen_pre = true;
            try testing.expectEqual(@as(usize, 2), pl.group_index); // 사용자 둘 뒤
        } else {
            try testing.expectEqual(@as(usize, 0), pl.group_index); // 새로 만든 이벤트는 첫 자리
        }
    }
    try testing.expect(seen_pre);
}

test "담을 자리가 모자라면 그 사실이 드러난다 — 조용히 자르지 않는다" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const want = try wantCommand(a);
    const after_text = try runClaude(a, "{}", want, .install);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, after_text, .{});

    var one: [1]Placement = undefined;
    const n = ourPlacements(parsed.value.object.get("hooks"), want, &one);
    try testing.expectEqual(@as(usize, command.claude_events.len), n); // 총 개수를 돌려준다
    try testing.expect(n > one.len);
}

test "provider 별 자리: 환경 변수 우선, 빈 값은 설정하지 않음과 같다" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/opt/claude", configDir(.claude, &buf, "/opt/claude", "/Users/a").?);
    try testing.expectEqualStrings("/Users/a/.claude", configDir(.claude, &buf, null, "/Users/a").?);
    try testing.expectEqualStrings("/Users/a/.claude", configDir(.claude, &buf, "", "/Users/a").?);
    try testing.expectEqualStrings("/opt/codex", configDir(.codex, &buf, "/opt/codex", "/Users/a").?);
    try testing.expectEqualStrings("/Users/a/.codex", configDir(.codex, &buf, null, "/Users/a").?);
    try testing.expectEqual(@as(?[]const u8, null), configDir(.codex, &buf, null, null));

    // 두 provider 가 같은 자리를 가리키면 한쪽 설치가 다른 쪽을 덮는다.
    try testing.expect(!std.mem.eql(u8, homeSubdir(.claude), homeSubdir(.codex)));
    try testing.expect(!std.mem.eql(u8, hooksFileName(.claude), hooksFileName(.codex)));
    try testing.expect(!std.mem.eql(u8, configDirEnv(.claude), configDirEnv(.codex)));
}
