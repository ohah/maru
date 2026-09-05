const std = @import("std");

// 이 테스트는 **"이 터미널이 서 있는 폴더"를 푸는 지점이 하나뿐이다**는 규율을 강제한다
// (docs/editor-surface-dock.md §3.5가 그 규칙의 단일 출처 — OSC 7 → 커널 조회 2단).
//
// **왜 필요한가.** 그 규칙은 2026-08-10에 생겼지만 **주석에만** 있었다. `term.rt.observation.cwd`는 평범한
// 공개 필드라 새 소비자를 만드는 사람이 `git_ops.termCwd`의 존재를 모른 채 그냥 읽으면 되고, 컴파일도 리뷰도
// 통과한다. 실제로 그렇게 갈렸다 — 2026-08-12 전수 조사에서 **여섯 곳**이 옛 축에 남아 있었고, 그 결과
// 셸 통합이 없는 셸(bash/fish)과 재개 Term(`zsh -l -i -c "exec <provider> --resume"`은 프롬프트를 한 번도
// 그리지 않아 OSC 7을 평생 못 받는다)에서 아래가 전부 동시에 죽어 있었다:
//
//   - 사이드바 카드·에이전트 행의 폴더줄·브랜치줄
//   - 상태바의 폴더·브랜치 항목
//   - 사이드바 검색의 폴더명 매칭
//   - 에이전트 세션 기록 도크의 `현재 작업공간`·`현재 프로젝트` 칩(**겉모습은 그대로인데 눌리지 않았다** —
//     `enabled`는 paint가 아니라 hit-test만 바꾼다)
//   - 사이드바 에이전트 행의 마지막 대화(transcript 매핑)
//
// 사용자 제보 하나에서 다섯이 나왔다. 규칙을 산문에서 **게이트**로 옮기지 않으면 여섯 번째가 생긴다.
//
// **두 규칙을 건다.**
//   A. 직독(`observation.cwd`)이 일어나는 **함수 이름**을 파일별로 고정한다.
//   B. `observation`을 이름에 묶는 곳(별칭)의 **개수**를 파일별로 고정한다 — 별칭은 A를 우회할 수 있다.
//
// **테스트 블록은 세지 않는다.** 테스트는 관측을 일부러 심어 우선순위·폴백을 검증하므로, 그것까지 세면
// 재고가 테스트 변경마다 흔들려 규칙이 소음이 된다. 같은 규율이 `imports.zig`의
// `countIdentifierOutsideTopLevelTests`와 digest 원장("비-test 토큰")에 이미 있다.
//
// **범위는 GUI의 Term 관측이다** — `src/platform/macos/app_session*`. `session_host`의 `RuntimeObservation`은
// 그 값을 **만드는** 쪽(host→GUI wire)이라 이 규칙의 대상이 아니다. 2026-08-12 기준 이 트리 밖에서
// `.rt.observation`을 만지는 제품 코드는 **없다**(전수 확인).
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - 기존 별칭이 나중에 `.cwd`를 읽기 시작하면 두 규칙 다 침묵한다. 잡으려면 데이터플로 분석이 필요하고
//     토크나이저로는 안 된다.
//   - `@field(observation, "cwd")` 같은 반사도 못 본다(2026-08-12 기준 이 트리에 그런 코드는 없다).
//   - 디렉터리 순회는 **비재귀**다. `app_session/` 아래에 하위 디렉터리를 만들면 그 안은 안 본다
//     (지금은 없다 — 생기면 순회를 재귀로 바꿔야 한다).
//   더 넓은 규칙(`.cwd` **전체**를 세기)도 재 봤는데 이 트리에 76곳이라(대부분 `req.cwd`·
//   `record.parsed.cwd` 같은 무관한 필드) 재고가 소음이 되어 규칙이 죽는다. 여기까지가 실제 경계다 —
//   더 넓은 척하지 않는다.

/// 정당한 직독과 그 이유. **새로 늘리려면 여기에 이유를 적어야 한다** — 그게 이 게이트의 목적이다.
/// 대부분의 새 소비자는 여기 오는 대신 `git_ops.termCwd`(저장소 판정용) 또는 `git_ops.termCwdForDisplay`
/// (표시용 — 원격은 host 접두를 붙일 수 있게 관측 경로를 남긴다)를 써야 한다.
const Entry = struct {
    path: []const u8,
    /// 직독이 허용된 **함수 이름들**(소스 등장 순서). 개수가 아니라 이름을 박는 이유는
    /// `collectObservationCwdFns` 주석 참조 — 개수만 박으면 "정당한 하나를 빼고 부정한 하나를 더하는"
    /// 변경이 총합을 보존해 통과한다(적대적 검증 7회차에서 실제로 뚫었다).
    fns: []const []const u8,
    /// `observation`을 이름에 묶는 곳(별칭)의 수. 규칙 B가 고정한다 — out 파라미터는 제외다.
    aliases: usize,
    why: []const u8,
};

const inventory = [_]Entry{
    .{
        .path = "src/platform/macos/app_session.zig",
        .fns = &.{ "termCwdIsRemote", "respawnEndedPlaceholder", "writeEndedPlaceholderGuidance", "currentCwd", "pinTermsOutsideRepo", "pinTermsOutsideRepo" },
        .aliases = 2,
        .why =
        \\전부 Q1이다 — 셸이 보고한 값 **그 자체**가 답이라 커널 값으로 대체할 수 없다.
        \\  - termCwdIsRemote: OSC 7 authority(host) 판정 그 자체 — 커널 값엔 host가 없다
        \\  - 묘비(ended placeholder) 복원 spawn cwd: "마지막으로 셸이 보고한 값"으로 되살린다
        \\  - 묘비 안내 텍스트: 같은 이유. 프로세스는 이미 죽어 커널에 물을 대상이 없다
        \\  - currentCwd: 제품 소비자가 0인 ABI(그 주석 참조). 소비자가 생기면 축부터 정해야 한다
        \\
        \\`collectSessionInto`(제어 평면 `TerminalMeta.cwd`)는 여기 **있었다가 빠졌다** — 축(`termCwdForDisplay`)
        \\으로 이관했다. 다시 들어오려 하면 그건 wire가 GUI와 갈라지는 것이므로 이유부터 적어야 한다.
        \\
        \\`sidebarCwdPath`의 원격 분기는 여기 없다 — 그건 `cwd_host`를 읽지 `cwd`를 읽지 않는다.
        \\(첫 재고에 그것을 6번째로 잘못 적었고, 이 게이트가 스스로 그 오류를 잡았다.)
        \\별칭 둘은 `app_cursor_keys`·`kitty_flags`·`mouse_tracking_mode` 등을 읽는다. cwd는 안 읽는다.
        \\
        \\`pinTermsOutsideRepo`(둘)는 **테스트 픽스처**다 — 축을 우회해 읽는 것이 아니라 축의 **입력을
        \\심는다**(관측값을 비우고 `/tmp`를 넣는다). 저장소 목록이 터미널 cwd에서 나오게 된 뒤(P3d),
        \\스모크 Term은 OSC 7이 없어 커널 cwd(= 테스트 프로세스의 저장소)로 폴백해 **테스트가 어디서
        \\도는지에 따라 목록이 갈렸다**. 심는 값이 저장소가 아닌 곳이라 그 새는 길이 닫힌다.
        ,
    },
    .{
        .path = "src/platform/macos/app_session/git.zig",
        .fns = &.{ "remoteCwd", "termCwd" },
        .aliases = 0,
        .why =
        \\축 자체 — 로컬은 `termCwd`의 1단(OSC 7), 원격은 `remoteCwd`다.
        \\
        \\`remoteCwd`(RS6 — docs/plans/remote-scm.md §17)는 **축의 반대편**이라 여기 있다. 로컬 축은
        \\원격에서 의도적으로 null 을 낸다(그 경로를 로컬에 대고 해석하면 남의 저장소를 만진다 — §9.4).
        \\그래서 「원격 pane 은 어디에 서 있나」에는 그 축이 답할 수 없고, 관측(그리고 전면 TUI 구간을
        \\메우는 훅 cwd)이 유일한 소스다.
        \\
        \\**재고가 셋에서 둘로 줄었다.** 예전에는 `termCwdForDisplay`(표시)와 `remoteScmTarget`(원격 SCM)이
        \\각자 관측을 직독했고, 그래서 같은 pane 에서 폴더줄과 도크가 **다른 답**을 냈다(원격에서 `claude` 를
        \\띄우면 OSC 7 이 멈춰 도크만 홈을 봤다 — 사용자 보고 2026-09-05). 둘 다 이제 `remoteCwd` 를 부른다.
        \\
        \\**직독이 여기 하나로 묶여 있는 것이 이 함수의 값어치다**: 원격 cwd 가 한 곳이라 표시·목록·diff·쓰기가
        \\같은 쌍을 보고, 「목록은 원격인데 클릭은 로컬」이 원리적으로 불가능해진다. 다른 곳에서 원격 cwd 를
        \\또 직독하면 그 보장이 깨지므로, 그때는 이 함수를 부르지 재고를 늘리지 않는다.
        ,
    },
    .{
        .path = "src/platform/macos/app_session/debug_fixtures.zig",
        .fns = &.{},
        .aliases = 1,
        .why =
        \\**디버그 픽스처다**(`MARU_FORCE_REMOTE_SCM`, env-gate). 축을 우회해 읽는 것이 아니라 축의
        \\**입력을 심는다** — `pinTermsOutsideRepo`(위 항목)와 같은 부류다.
        \\
        \\심는 것은 `maru ssh` 가 보내는 것과 **같은 바이트**(OSC 5379 + OSC 7)이고, 관측을 읽는 이유는
        \\**이미 그 상태면 안 쓰기 위해서**다. 매 frame 다시 적용해야 하는데(진짜 로컬 셸이 다음
        \\프롬프트에 OSC 7 로 되돌린다), 매번 쓰면 코어가 계속 깨어난다.
        \\
        \\`git_repo_dest` 를 손으로 대입하지 **않는** 것이 이 픽스처의 값어치다. 그렇게 하면 그 아래
        \\배선(`remoteScmTarget` → control socket 확인 → 읽기 라우팅)이 통째로 안 돌아, 화면이 그럴듯한데
        \\제품은 깨져 있을 수 있다. 실제로 이 픽스처가 **소켓 없는 원격 pane 이 로컬 저장소를 보여 주던
        \\결함**을 제품 렌더 캡처로 드러냈다(2026-09-02).
        ,
    },
    .{
        .path = "src/platform/macos/app_session/agent.zig",
        .fns = &.{},
        .aliases = 1,
        .why =
        \\직독은 없다 — transcript 매핑은 2026-08-12에 축(`git_ops.termCwd`)으로 옮겼다.
        \\별칭 하나가 `availability`·`observer_generation`을 읽는다(에이전트 상태 판정). cwd는 안 읽는다.
        ,
    },
    .{
        .path = "src/platform/macos/app_session/scroll.zig",
        .fns = &.{},
        .aliases = 1,
        .why = "직독 없음. 별칭 하나가 `alt_active`·`alternate_scroll`·`app_cursor_keys`를 읽는다(휠 라우팅).",
    },
    .{
        .path = "src/platform/macos/app_session/tab.zig",
        .fns = &.{"captureWorkspaceTab"},
        .aliases = 0,
        .why = "Q3(영속화) — workspace capture가 저장할 값. 복원 계약이 따로 판단할 문제라 축과 분리한다.",
    },
    .{
        .path = "src/platform/macos/app_session/term.zig",
        .fns = &.{ "focusedTermCwd", "logScreenIfDebug" },
        .aliases = 1,
        .why =
        \\  - focusedTermCwd: 새 탭·split이 상속할 cwd(Ghostty `*-inherit-working-directory` 모델).
        \\    셸이 보고한 값을 물려주는 것이 그 계약이라 Q1으로 둔다 — 재분류 여지는 있다.
        \\  - 진단 로그: 표시·판정에 안 쓰인다
        \\별칭 하나는 `availability`·`bracketed_paste`를 읽는다. cwd는 안 읽는다.
        ,
    },
};

const scan_root_file = "src/platform/macos/app_session.zig";
const scan_root_dir = "src/platform/macos/app_session";

fn readZigFileZ(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    // app_session.zig가 이미 3.4 MiB다 — 상한에 닿아 게이트가 조용히 죽지 않게 넉넉히 잡는다.
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(64 * 1024 * 1024), .of(u8), 0);
}

/// 직독(`observation.cwd`)이 일어난 **함수 이름**을 등장 순서대로 모은다(테스트 블록 밖만).
/// `cwd_host`는 다른 식별자라 안 잡힌다.
///
/// **개수가 아니라 이름인 이유**: 개수만 박으면 같은 파일에서 정당한 직독 하나를 없애고 부정한 직독
/// 하나를 더하는 변경이 총합을 보존해 게이트를 통과한다(적대적 검증 7회차에서 실제로 뚫었다).
fn collectObservationCwdFns(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var saw_observation = false;
    var saw_period_after_observation = false;
    var saw_fn = false;
    var current_fn: []const u8 = "<파일 최상위>";
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return,
            .keyword_fn => {
                saw_fn = true;
                saw_observation = false;
                saw_period_after_observation = false;
            },
            .keyword_test => {
                if (brace_depth == 0 and test_body_depth == null) waiting_for_test_body = true;
                saw_observation = false;
                saw_period_after_observation = false;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
                saw_observation = false;
                saw_period_after_observation = false;
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth) test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
                saw_observation = false;
                saw_period_after_observation = false;
            },
            .period => {
                saw_period_after_observation = saw_observation;
                saw_observation = false;
            },
            .identifier => {
                const text = source[token.loc.start..token.loc.end];
                if (saw_fn) {
                    current_fn = text; // `fn <name>` — 이 뒤의 직독은 이 함수 것이다
                    saw_fn = false;
                }
                if (saw_period_after_observation and std.mem.eql(u8, text, "cwd") and test_body_depth == null)
                    try out.append(allocator, current_fn);
                saw_observation = std.mem.eql(u8, text, "observation");
                saw_period_after_observation = false;
            },
            else => {
                saw_observation = false;
                saw_period_after_observation = false;
            },
        }
    }
}

/// `observation`을 **값으로 넘겨받는** 곳(별칭)을 센다 — 대입(`=`) 또는 `return` 문맥에서 `.observation`을
/// 필드 접근으로 끝내는 형태다: `const obs = &x.rt.observation;` · `return &x.rt.observation;` ·
/// `var h = H{ .o = &x.rt.observation };`. 셋 다 그 참조로 `.cwd`를 읽으면 규칙 A를 우회한다.
///
/// **out 파라미터(`f(&x.rt.observation, ...)`)는 세지 않는다.** 그건 관측을 **채우는** 쪽
/// (`readObservation`)이라 우회로가 아니고, 함께 세면 정당한 새 호출이 의심스러운 별칭과 똑같이 걸려
/// 신호가 희석된다. 인자 자리인지 대입 자리인지는 **앞 토큰**으로 가른다 — 인자는 `(`/`,` 뒤에 오고,
/// 별칭·반환·필드 담기는 `=`/`return` 뒤에 온다. (첫 판은 **뒤** 토큰이 `;`인지로 갈랐는데, 그러면
/// 구조체에 담는 형태가 `}`로 끝나 통째로 빠져나갔다 — 적대적 검증 4회차.)
fn countObservationAliasesOutsideTests(source: [:0]const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var count: usize = 0;
    var pending = false;
    var saw_period = false;
    var binding_context = false;
    while (true) {
        const token = tokenizer.next();
        if (pending) {
            if (token.tag != .period and binding_context and test_body_depth == null) count += 1;
            pending = false;
        }
        switch (token.tag) {
            .eof => return count,
            .keyword_test => {
                if (brace_depth == 0 and test_body_depth == null) waiting_for_test_body = true;
                saw_period = false;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
                saw_period = false;
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth) test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
                saw_period = false;
            },
            .period => saw_period = true,
            .equal, .keyword_return => {
                binding_context = true;
                saw_period = false;
            },
            .semicolon, .comma, .l_paren, .r_paren => {
                binding_context = false;
                saw_period = false;
            },
            .identifier => {
                if (saw_period and std.mem.eql(u8, source[token.loc.start..token.loc.end], "observation"))
                    pending = true;
                saw_period = false;
            },
            else => saw_period = false,
        }
    }
}

fn sameFnList(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, e| if (!std.mem.eql(u8, a, e)) return false;
    return true;
}

fn printList(items: []const []const u8) void {
    if (items.len == 0) {
        std.debug.print("(없음)", .{});
        return;
    }
    for (items, 0..) |item, i| std.debug.print("{s}{s}", .{ if (i == 0) "" else ", ", item });
}

fn lookup(path: []const u8) ?Entry {
    for (inventory) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

test "cwd 축: 직독은 재고에 적힌 함수에서만, 별칭은 적힌 개수만큼만" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try paths.append(allocator, try allocator.dupe(u8, scan_root_file));
    var dir = try std.Io.Dir.cwd().openDir(io, scan_root_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scan_root_dir, entry.name }));
    }

    var failed = false;
    var seen: [inventory.len]bool = .{false} ** inventory.len;
    for (paths.items) |path| {
        const source = try readZigFileZ(allocator, io, path);
        defer allocator.free(source);
        var fns: std.ArrayList([]const u8) = .empty;
        defer fns.deinit(allocator);
        try collectObservationCwdFns(allocator, source, &fns);
        const aliases = countObservationAliasesOutsideTests(source);

        if (lookup(path)) |entry| {
            for (inventory, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) {
                seen[i] = true;
            };
            if (!sameFnList(fns.items, entry.fns)) {
                std.debug.print("\n[cwd 축] {s}: 직독하는 함수 목록이 재고와 다르다.\n  실제: ", .{path});
                printList(fns.items);
                std.debug.print("\n  재고: ", .{});
                printList(entry.fns);
                std.debug.print(
                    \\
                    \\  늘었다면: 대개는 `git_ops.termCwd`(저장소 판정) 또는 `git_ops.termCwdForDisplay`(표시)를
                    \\  써야 한다 — 규칙은 docs/editor-surface-dock.md §3.5가 단일 출처다. 그래도 직독이 맞다면
                    \\  이 파일의 재고에 **이유와 함께** 함수 이름을 올려라.
                    \\  줄었다면: 재고에서 빼라(축으로 옮긴 것을 축하한다).
                    \\  자리만 옮겼다면: 개수가 같아도 통과시키지 않는다 — 그게 이름을 박는 이유다.
                    \\  현재 재고 사유:
                    \\{s}
                    \\
                , .{entry.why});
                failed = true;
            }
            if (aliases != entry.aliases) {
                std.debug.print(
                    \\
                    \\[cwd 축] {s}: `observation` 별칭이 {d}개인데 재고는 {d}개다.
                    \\  별칭(`const obs = &term.rt.observation;`)은 규칙 A를 **우회할 수 있다**. 그 별칭으로
                    \\  cwd를 읽을 생각이면 `git_ops.termCwd`를 써라. 다른 필드를 읽는 것이라면 이 파일의
                    \\  `aliases`를 올려라.
                    \\
                , .{ path, aliases, entry.aliases });
                failed = true;
            }
        } else if (fns.items.len != 0 or aliases != 0) {
            // **직독이 0이어도 별칭이 있으면 재고에 와야 한다.** 안 그러면 "직독 0"인 파일이 규칙 B의
            // 사각지대가 되어, 거기서 별칭으로 cwd를 읽어도 아무도 안 본다.
            std.debug.print(
                \\
                \\[cwd 축] {s}: 재고에 없는 파일이 `observation`을 만진다(직독 {d}회, 별칭 {d}회).
                \\  cwd가 필요한 것이면 `git_ops.termCwd`(저장소 판정) 또는 `git_ops.termCwdForDisplay`
                \\  (표시)를 써라. 다른 필드를 읽는 것이라면 이 파일의 재고에 이유와 함께 추가하라.
                \\
            , .{ path, fns.items.len, aliases });
            failed = true;
        }
    }

    // **재고에 남은 유령을 잡는다.** 파일이 사라졌거나 이름이 바뀌었는데 재고만 남으면, 그 항목이 아무것도
    // 지키지 않으면서 규칙을 지키는 것처럼 보인다.
    for (inventory, 0..) |entry, i| if (!seen[i]) {
        std.debug.print("\n[cwd 축] 재고에 있는 {s}를 스캔 대상에서 찾지 못했다(이동·삭제?).\n", .{entry.path});
        failed = true;
    };

    if (failed) return error.CwdAxisInventoryMismatch;
}

test "cwd 축 스캐너(규칙 A): 함수 이름을 붙이고 테스트 블록과 cwd_host는 뺀다" {
    const allocator = std.testing.allocator;
    const fixture =
        \\fn produce(term: *Term) void {
        \\    const a = term.rt.observation.cwd.items;
        \\    const b = term.rt.observation.cwd_host.items;
        \\    _ = a;
        \\    _ = b;
        \\}
        \\fn other(term: *Term) void {
        \\    _ = term.rt.observation.cwd.items;
        \\}
        \\test "planting is fine" {
        \\    term.rt.observation.cwd.appendSlice(a, "/tmp");
        \\}
    ;
    var fns: std.ArrayList([]const u8) = .empty;
    defer fns.deinit(allocator);
    try collectObservationCwdFns(allocator, fixture, &fns);
    try std.testing.expect(sameFnList(fns.items, &.{ "produce", "other" }));
}

test "cwd 축 스캐너(규칙 A): 중첩 함수는 가장 안쪽 이름으로 붙는다" {
    // 익명 struct 안의 `fn`으로 직독을 숨기면 어느 이름이 붙는지 고정한다. 가장 최근 `fn <name>`을 쓰므로
    // `inner`가 잡힌다 — 재고에 없는 이름이라 게이트가 걸린다. 바깥 이름(`outer`)으로 잘못 붙으면 허용된
    // 함수 뒤에 숨길 수 있으므로, 이 픽스처가 그 회귀를 막는다(적대적 검증 9회차).
    const allocator = std.testing.allocator;
    const nested =
        \\fn outer(t: *Term) void {
        \\    const S = struct {
        \\        fn inner(x: *Term) usize { return x.rt.observation.cwd.items.len; }
        \\    };
        \\    _ = S.inner(t);
        \\}
    ;
    var fns: std.ArrayList([]const u8) = .empty;
    defer fns.deinit(allocator);
    try collectObservationCwdFns(allocator, nested, &fns);
    try std.testing.expect(sameFnList(fns.items, &.{"inner"}));
}

test "cwd 축 스캐너(규칙 B): 별칭·반환·구조체 담기는 세고 out 파라미터는 안 센다" {
    // 이 픽스처가 없으면 규칙 B가 무엇을 잡는지 코드로 증명되지 않는다. 첫 판(뒤 토큰이 `;`인지로 판별)은
    // 아래 `struct_field` 형태를 통째로 놓쳤고, 이 테스트가 그 회귀를 막는다(적대적 검증 4회차).
    const alias =
        \\fn f(t: *Term) void { const obs = &t.rt.observation; _ = obs; }
    ;
    const returned =
        \\fn g(t: *Term) *Obs { return &t.rt.observation; }
    ;
    const struct_field =
        \\fn h(t: *Term) void { var x = H{ .o = &t.rt.observation }; _ = x; }
    ;
    const out_param =
        \\fn i(t: *Term) void { be.readObservation(t.rt.handle, a, &t.rt.observation, false) catch {}; }
    ;
    const in_test =
        \\test "planting" { const obs = &t.rt.observation; _ = obs; }
    ;
    try std.testing.expectEqual(@as(usize, 1), countObservationAliasesOutsideTests(alias));
    try std.testing.expectEqual(@as(usize, 1), countObservationAliasesOutsideTests(returned));
    try std.testing.expectEqual(@as(usize, 1), countObservationAliasesOutsideTests(struct_field));
    try std.testing.expectEqual(@as(usize, 0), countObservationAliasesOutsideTests(out_param));
    try std.testing.expectEqual(@as(usize, 0), countObservationAliasesOutsideTests(in_test));
}
