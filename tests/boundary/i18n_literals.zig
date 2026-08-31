// 이 테스트는 **"번역 대상 레이어에 새 한국어 리터럴이 들어오지 않는다"** 를 강제한다
// (docs/i18n.md §7.2 의 2 차 방어).
//
// **무엇을 증명하나.** 표시 문자열은 `src/i18n.zig` 의 테이블이 소유하고 코드는 키만 든다. 그 규율이
// 지켜지는 한 언어를 바꾸면 화면 전체가 따라오지만, **한 자리라도 리터럴로 새면 그 자리만 한국어로
// 남는다** — 크래시도 경고도 없이. 계약 §7.2 는 1 차 방어(파라미터를 `i18n.Key` 로)를 세울 수 없는
// sink 가 있다고 적었다(`context_menu_items_buf` 처럼 정적·동적이 한 배열에 섞이는 자리). 거기서는
// 이 검사가 유일한 방어다.
//
// **원장을 올릴 때는 그것이 표시 문자열이 아님을 확인한다.** 이 게이트가 처음 잡은 둘이 그 예다:
// SCM 히스토리 탭의 상대 시각·안내 9 건은 **표시 문자열이라 키로 옮겼고**(원장 0 유지),
// CoreText 스모크의 9 건은 **디버그 출력 2 + 스모크 fixture 7**(탭 제목·기본 텍스트)이라 원장을 올렸다.
// 늘었다는 사실만으로 자동 반영하면 게이트가 아무것도 안 지킨다 — 매번 그 자리를 열어 봐야 한다.
//
// **왜 개수 원장인가.** 남은 것(수는 `header_total`·`header_config_total` 이 comptime 에 검증한다)은
// 대부분 **표시 문자열이 아니다** — config 파싱 진단,
// Chrome Lab 개발 도구, 계약 §6.2 위반이라 I2 가 먼저 드는 자리(정렬 공백·아이콘 결합), trace
// 로그. 그것들을 0 으로 만드는 것은 이 계약의 일이 아니므로 **현재 수를 고정**하고 **늘면 실패**시킨다.
// 줄이는 것은 언제나 환영이고, 그때는 원장을 함께 줄이라고 안내한다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - **줄어든 것은 못 막는다.** 원장보다 적으면 실패하지 않고 "원장을 줄여라"만 말한다(그 편이
//     리팩터를 막지 않는다). 대신 그 안내를 놓치면 원장이 헐거워지므로, 줄었을 때도 실패시킨다.
//   - **한글이 아닌 표시 문자열은 못 본다.** 영어로 박은 리터럴은 이 검사를 통과한다 — 그것은
//     1 차 방어(타입)와 리뷰의 몫이다.
//   - **주석·`test` 블록은 제외**하므로 그 안의 한글은 세지 않는다. 제품 경로만 본다.
//   - 문자열 안의 `//` 를 주석으로 오인하지 않도록 따옴표 상태를 추적하지만, 여러 줄 문자열
//     (`\\`)은 줄 단위로 본다 — 그 안의 한글은 세지 않는다(현재 트리에 표시용은 없다).
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// 번역 대상 레이어 — 여기서는 표시 문자열이 **키로** 가야 한다(§7.2).
const roots = [_][]const u8{ "src/chrome", "src/session", "src/platform/macos", "src/platform/mobile", "src/config" };

/// 뿌리 **밖에 있는데 표시 문자열을 그리는** 파일. 디렉터리로는 못 덮는 자리를 파일 단위로 덮는다.
///
/// `src/platform/cell_text.zig` 가 그 예다 — macOS·Windows 가 공유하는 셀 투영이라 `platform/macos` 도
/// `platform/mobile` 도 아닌 `src/platform/` 바로 아래 산다. 그런데 이 파일은 `i18n.t(...)` 로 최근 파일
/// 헤더·빈 트리 안내를 그린다. 뿌리에 안 들면 **표시 문자열을 그리는 파일이 방어 밖**이 되고, 그 사실은
/// 파일을 옮긴 그 순간 조용히 생긴다(FT3 이동에서 실제로 그랬다 — 적대적 검증이 잡았다).
///
/// `src/platform` 전체를 뿌리로 넣지 않는 이유: Windows·wasm 어댑터가 진단·usage 문자열을 한국어로
/// 들고 있어(실측 170건 이상) 이 게이트의 범위가 통째로 달라진다. 그것은 별도 판단이다.
const extra_files = [_][]const u8{"src/platform/cell_text.zig"};

/// **영어 고정 표면**(계약 §7.1) — CLI 는 스크립트가 파싱하고 이슈에 붙여 넣는 출력이라 언어를 고르지
/// 않는다. 그래서 여기서는 키가 아니라 **영어 문장**이 정답이고, 한국어 리터럴은 곧 위반이다.
///
/// 원장은 **거의 비어 있다** — I5 가 CLI 137 건을 영어로 옮겼다. 남은 항목이 0 이 되면 원장에서 빼고,
/// 그러면 그 파일은 "한국어 0" 이 기본값이 되어 한 건만 들어와도 실패한다.
const english_only_roots = [_][]const u8{"src/cli"};
const english_only_files = [_][]const u8{"src/main.zig"};

/// 표 자신. 이 **경로**만 면제한다(이름으로 빼면 아무 데나 `*i18n.zig` 를 두고 우회할 수 있다).
///
/// 오늘 `roots` 는 표를 담지 않으므로 이 면제는 **안 걸린다** — 표가 훑는 뿌리 아래로 옮겨졌을 때를
/// 위한 것이다. 그때 이름 비교였으면 우회가 함께 열린다.
const table_path = "src/i18n.zig";

const Entry = struct { path: []const u8, count: usize };

/// 파일별 남은 한국어 리터럴 수. **늘면 실패**하고, **줄어도 실패**한다(원장을 함께 줄이라는 뜻).
/// 새 파일이 한글 리터럴을 들고 나타나면 원장에 없으므로 실패한다 — 그것이 이 게이트의 본래 목적이다.
const inventory = [_]Entry{
    // ── 영어 고정 표면(§7.1) ──
    // **토크나이저로 바꾸자 드러난 것들.** 줄 단위 스캐너는 멀티라인 문자열(`\\`)을 못 봤다.
    //   · `cli/browser.zig`(20) 와 `main.zig`(1) 은 **0 이 되어 원장에서 빠졌다.** 둘 다 §7.1 이 영어로
    //     고정한 표면인데 한국어였다 — 계약이 금지한 것이 코드에 있었고, 이 원장이 그것을 "알려진 위반"
    //     으로 세고 있었다. `maru browser --help` 본문과 Windows 스모크 usage 한 줄을 영어로 옮겼다.
    //     CLI 출력을 영어로 두는 이유는 §7.1 이 적은 대로 **스크립트가 파싱하기 때문**이다.
    // `cli/browser/run.zig`(41) 도 **0 이 되어 빠졌다**. `cli/ssh.zig` 에 남은 하나는
    // `@compileError` 라 개발자 메시지이고 §7.1 대상이 아니다 — 그 사실을 그 자리 주석이 든다.
    .{ .path = "src/cli/ssh.zig", .count = 1 },

    // ── 번역 대상 레이어(§7.2) ──
    // **표시 문자열이 아닌 것들** — 토크나이저 전환으로 드러났고, 각각 성격을 확인해 등재했다.
    //   · `shell_integration.zig` 48 — maru 가 쓰는 **셸 스크립트 본문·주석**이다. 사용자가 파일을
    //     열면 보지만 앱 UI 가 아니고, `agent_statusline` 의 설치 마커처럼 **파일 포맷의 일부**다.
    //   · `agent_statusline.zig` 5 — **셸 훅 스크립트 본문 3줄 + settings.json 에 쓰는 설치 마커 2개**다.
    //     바로 위 `shell_integration` 과 같은 성격(파일 포맷의 일부)이지 doc 주석이 아니다 — 새 스캐너는
    //     doc 주석을 애초에 토큰으로 세지 않으므로 그 근거는 성립할 수 없었다.
    //   · `remote_runtime.zig` 3 — 진단 문자열.
    .{ .path = "src/platform/macos/shell_integration.zig", .count = 48 },
    // `components/settings.zig`(8) 은 **0 이 되어 빠졌다.** 키 힌트·색 선택기·단축키 녹음 문구가
    // comptime `const` 라 언어를 못 탔다 — 값이 컴파일 시점에 박히므로 `t()` 를 넣어도 안 바뀐다.
    // 상수를 **함수로** 바꿔야 언어 전환이 다음 프레임에 따라온다. 폭 계산과 그리기가 같은 문자열을
    // 봐야 하므로 한 자리에서 준다.
    .{ .path = "src/chrome/ui/visual_map.zig", .count = 1 },
    // 25 → 26: `theme.syntax.<역할>`의 **모르는 역할 이름 진단**이 늘었다(native-editor-ui.md §9.0).
    // 이 파일의 다른 스물다섯과 같은 부류다 — 사용자에게 그리는 문자열이 아니라 config 로더가 파일의
    // 그 줄을 왜 무시했는지 적는 **진단**이고, 같은 규율으로 한국어를 유지한다(docs/i18n.md §7 — "표시가
    // 아니면 그 사실을 주석에 적고 원장을 올린다").
    .{ .path = "src/config/loader.zig", .count = 26 },
    .{ .path = "src/config/schema.zig", .count = 28 },
    .{ .path = "src/platform/macos/agent_session_archive_backend.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_pty_metal_smoke.zig", .count = 1 },
    // 26 = 16 + 원격(ssh) 축의 **진단 로그 열**(§7 의 «표시가 아니면 원장을 올린다»).
    // 전부 `std.log.scoped(.agent)` 이고 사용자 화면에 안 나온다 — 채널이 잡음으로 막혔을 때, 자식이
    // 끝나 관측 모드로 내려갈 때, 원격 훅을 심었을 때·이미 있을 때, 원격에 maru 가 없을 때, 설치 결과를
    // 못 읽었을 때, 설치가 시한 안에 안 끝났을 때, `HOME` 이 없을 때, control socket 경로를 못 만들 때,
    // 스트리머를 못 띄웠을 때 **원인을 남기는 줄**이다.
    //
    // ⚠️ **이 줄들을 «없어도 되는 것» 으로 읽으면 안 된다.** 계약 §1.2 가 조용한 폴백을 금지하고,
    // 적대적 검증이 실제로 «사유 없이 끝나는 막다른 길» 셋을 그 규칙으로 잡아냈다 — 늘어난 넷 중
    // 셋이 그것이다.
    .{ .path = "src/platform/macos/app_session.zig", .count = 26 },
    .{ .path = "src/platform/macos/app_session/debug_fixtures.zig", .count = 3 },
    // **표시 문자열이 아니라 판정자의 진단 출력이다**(§7 "표시가 아니면 그 사실을 적고 원장을
    // 올린다"). DSEL3가 그려진 글자와 클릭이 답한 byte를 대조하다 어긋나면 그 자리를 사람이 읽을
    // 수 있게 한 줄 찍는다 — 실패했을 때만 나오고 화면에는 영영 안 간다.
    .{ .path = "src/platform/macos/app_session/editor_diff.zig", .count = 1 },
    .{ .path = "src/platform/macos/app_session/settings.zig", .count = 1 },
    // `sidebar.zig`(3) 는 **0 이 되어 빠졌다.** 에이전트 상태줄 넷 중 running 만 키를 거치고 나머지
    // 셋(`입력 대기`·`대기중`·`상태 확인 중`)이 한국어 리터럴이라, 영어 화면에서 **한 줄 안에 언어가
    // 섞였다**(사용자 보고). 같은 자리에 서는 문구는 함께 옮겨야 한다는 것이 그 사고의 형태다.
    .{ .path = "src/platform/macos/app_session/term.zig", .count = 1 },
    // **표시 문자열이 아니라 캡처 픽스처다**(§7 "표시가 아니면 그 사실을 적고 원장을 올린다").
    // Lab은 골든 캡처용 합성 입력만 소유하고, 그 안의 한국어는 **그려지는 내용 자체**다 — 한글이
    // 두 칸으로 서는지·선택 띠가 어디까지 오는지를 픽셀로 보려면 한국어 문자열이 있어야 한다.
    // 16번째는 `editor_selection` 시나리오의 "선택 밖" 줄이다(띠가 거기까지 오면 안 된다는 대조군).
    // 17·18번째는 `editor_find` 시나리오의 두 줄이다 — 하나는 "매치가 넷"임을 캡처를 보는 사람에게
    // 말해 주는 대조군 주석이고, 다른 하나는 **한글 사이에 선 매치**다(멀티바이트 앞뒤에서 강조 열이
    // 밀리지 않는지는 한국어 줄이 있어야 픽셀로 보인다).
    // 19~30번째는 `scm_history` 시나리오의 커밋 제목·작성자다(2026-08-27). **사용자 캡처를 그대로
    // 재현한 픽스처**라 그 화면이 실제로 겪는 것 — 한글 제목이 좁은 도크에서 어디서 말줄임되는지,
    // 대괄호가 붙은 한국어 이름이 시각·해시를 밀어내지 않는지 — 을 픽셀로 보려면 한국어여야 한다.
    // 영어로 바꾸면 이 캡처가 증언하는 폭 산술이 통째로 다른 경우가 된다.
    // 31: caret 모양 fixture의 한글 줄("가나다 라마바"). **표시 문자열이 아니라 fixture다** —
    // `block`·`underline`이 2칸 글자를 제대로 덮는지는 ASCII만으로는 캡처에 안 나온다(§7 "표시가 아니면").
    // 33: `scm-blocker` 시나리오의 안내 두 줄("커밋 메시지를 입력하세요"·"변경 사항 없음"). 같은 이유로
    // fixture다 — **제품이 내는 문자열을 그대로 적어야** 캡처가 제품을 예고한다(`i18n.t` 로 부르면 그 키의
    // 값이 바뀔 때 골든이 조용히 따라가 색·자리 계약이 아니라 문구를 재게 된다).
    // 34: 구문 파싱이 상한 안에 안 끝났을 때의 **panic 문구**. 표시 문자열이 아니라 하네스
    // 진단이다(§7 "표시가 아니면") — 사람이 읽는 화면이 아니라 캡처를 만들다 죽는 자리다.
    // 조용히 빠지면 색 없는 그림이 골든이 되므로 문구는 원인을 그대로 말해야 한다.
    .{ .path = "src/platform/macos/chrome/lab.zig", .count = 34 },
    // 2 → 3: `editor_typescript` 캡처 픽스처의 한국어 주석 한 줄. **표시 문자열이 아니라 그려질
    // 내용**이다 — 캡처가 한글 폭까지 잡도록 일부러 넣었다(같은 파일의 다른 둘도 같은 부류다).
    .{ .path = "src/platform/macos/chrome_lab_smoke.zig", .count = 3 },
    .{ .path = "src/platform/macos/control_server.zig", .count = 1 },
    .{ .path = "src/platform/macos/coretext_smoke.zig", .count = 9 },
    .{ .path = "src/platform/macos/glyph_text_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/metal_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/remote_runtime.zig", .count = 3 },
    .{ .path = "src/platform/macos/session_host/remote_screen.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/remote_term_backend.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/shutdown_n1_baseline.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/test_scratch.zig", .count = 2 },
    // 데모 바이트를 없애며 0 이 됐다(그 안의 한국어가 마지막 리터럴이었다 — 화면 문구는
    // 이미 전부 `i18n` 키다). **원장은 늘 실측으로 내린다**: 남겨 두면 새 리터럴 셋이
    // 들어와도 게이트가 조용하다.
    .{ .path = "src/platform/mobile/mobile_bridge.zig", .count = 0 },
    // **표시가 아니라 컴파일 진단이다**(§7 의 셋째 경우). `absorb` 가 `client.Step` 의 필드 수를
    // comptime 으로 못박아 두는데, 그 `@compileError` 문구가 유일한 한국어 리터럴이다 — 사용자
    // 화면에는 한 글자도 안 간다(빌드가 멈추면서 개발자가 읽는다).
    .{ .path = "src/platform/mobile/mobile_ssh.zig", .count = 1 },
    .{ .path = "src/session/agent_observer.zig", .count = 3 },
    .{ .path = "src/session/agent_selection.zig", .count = 1 },
    .{ .path = "src/session/agent_statusline.zig", .count = 5 },
    .{ .path = "src/session/control_bridge.zig", .count = 1 },
};

fn isHangulLead(b: u8) bool {
    return b == 0xEA or b == 0xEB or b == 0xEC or b == 0xED;
}

fn hasHangul(bytes: []const u8) bool {
    for (bytes) |b| if (isHangulLead(b)) return true;
    return false;
}

/// 제품 경로(= top-level `test` 블록 **밖**)의 한국어 문자열 리터럴 수.
///
/// **토크나이저로 센다.** 예전에는 줄 단위로 `{`/`}` 를 세어 test 블록 끝을 찾았는데, 그 방식은
/// **문자열·주석 안의 중괄호까지 세어** 한 번 어긋나면 그 파일의 나머지 전부를 test 로 오인한다.
/// 실측에서 19 개 파일이 그렇게 막혀 있었고, 그중 `app_host_abi.zig` 는 198 행에서 멈춰 브라우저
/// 권한 **동의문 3 건**(로그인 쿠키 접근을 묻는 문장)이 게이트를 그냥 통과했다.
///
/// 옆의 `cli_purity.zig` 가 같은 문제를 이미 토크나이저로 풀었다 — 그 방식을 그대로 쓴다.
/// 파싱 오류가 있는 파일은 **실패**시킨다(조용히 0 을 세면 그 파일이 영원히 감시 밖이 된다).
fn countSource(allocator: std.mem.Allocator, source: [:0]const u8) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.SourceHasParseErrors;

    var in_test = try allocator.alloc(bool, tree.tokens.len);
    defer allocator.free(in_test);
    @memset(in_test, false);

    // **모든 `test` 블록**의 토큰을 마스킹한다. 깊이로 top-level 만 고르지 않는 이유: Zig 에서 `test` 는
    // top-level 이거나 struct 멤버뿐이고 **둘 다 테스트 코드**다. 깊이 추적은 `.{` 같은 토큰 때문에
    // 어긋나기 쉬운데, 한 번 어긋나면 test 이름 문자열까지 제품 코드로 세어 게이트가 거짓 경보를 낸다.
    const tags = tree.tokens.items(.tag);
    var token: std.zig.Ast.TokenIndex = 0;
    while (token < tree.tokens.len) {
        if (tags[token] == .keyword_test) {
            var cursor = token;
            var body_depth: usize = 0;
            var body_started = false;
            while (cursor < tree.tokens.len) : (cursor += 1) {
                in_test[cursor] = true;
                switch (tags[cursor]) {
                    .l_brace => {
                        body_started = true;
                        body_depth += 1;
                    },
                    .r_brace => {
                        if (!body_started or body_depth == 0) return error.SourceHasParseErrors;
                        body_depth -= 1;
                        if (body_depth == 0) break;
                    },
                    else => {},
                }
            }
            if (!body_started or body_depth != 0 or cursor == tree.tokens.len) return error.SourceHasParseErrors;
            token = cursor + 1;
            continue;
        }
        token += 1;
    }

    // 문자열 리터럴 토큰만 센다 — 주석은 애초에 토큰이 아니고, 멀티라인(`\\`)도 여기서 잡힌다.
    var total: usize = 0;
    for (tree.tokens.items(.tag), 0..) |tag, i| {
        if (in_test[i]) continue;
        switch (tag) {
            .string_literal, .multiline_string_literal_line => {
                if (hasHangul(tree.tokenSlice(@intCast(i)))) total += 1;
            },
            else => {},
        }
    }
    return total;
}

/// 헤더가 말하는 총계. **코드가 검증한다** — 손으로 적은 숫자는 원장이 움직일 때 조용히 어긋난다
/// (실제로 152 로 적혀 있다가 182 와 30 차이가 났다).
const header_total = 211;
const header_config_total = 54;

comptime {
    // 원장이 커서 기본 분기 한도(1000)를 넘는다.
    @setEvalBranchQuota(200_000);

    var sum = 0;
    var config_sum = 0;
    for (inventory) |e| {
        sum += e.count;
        if (std.mem.startsWith(u8, e.path, "src/config/")) config_sum += e.count;
    }
    if (sum != header_total)
        @compileError(std.fmt.comptimePrint("원장 합계가 {d} 인데 이 파일 머리는 {d} 라고 적었다", .{ sum, header_total }));
    if (config_sum != header_config_total)
        @compileError(std.fmt.comptimePrint("config 합계가 {d} 인데 머리는 {d} 라고 적었다", .{ config_sum, header_config_total }));
    // 같은 경로를 두 번 적으면 앞엣것이 이기고 뒤엣것은 죽은 줄이 된다 — 원장 자신의 불변식이다.
    for (inventory, 0..) |a, i| {
        for (inventory[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.path, b.path))
                @compileError("원장에 같은 경로가 두 번 적혀 있다: " ++ a.path);
        }
    }
}

/// 원장 항목이 실제로 소비됐는가. **소비 안 된 항목은 썩은 것**이고, 그것을 안 보면 파일이 사라진 뒤에도
/// 그 줄이 영원히 통과한다(형제 게이트 둘은 이 검사를 갖는데 이 파일만 없었다).
///
/// 파일 수준 `var` 라 이 파일에 둘째 테스트가 붙으면 첫 테스트의 소비 표시가 새어 나간다. 형제 게이트는
/// 테스트 지역 배열을 쓴다 — 여기는 `lookup` 이 파일 수준 함수라 그렇게 못 하므로, **테스트 시작에서
/// 반드시 지운다**.
var consumed = [_]bool{false} ** inventory.len;

fn lookup(path: []const u8) ?usize {
    for (inventory, 0..) |e, idx| {
        if (!std.mem.eql(u8, e.path, path)) continue;
        consumed[idx] = true;
        return e.count;
    }
    return null;
}

fn reportUnconsumed() bool {
    var ok = true;
    // `english_only_files` 는 원장에 없어 위 소비 검사가 못 닿는다 — 그 파일이 사라지면 §7.1 감시
    // 대상이 통째로 없어지는데 조용하다(실측). 여기서 존재만 확인한다.
    for (english_only_files) |f| {
        std.Io.Dir.cwd().access(std.testing.io, f, .{}) catch {
            ok = false;
            std.debug.print("영어 고정 대상 {s} 를 못 찾았다 — 옮겨졌거나 사라졌다. 목록을 고쳐라.\n", .{f});
        };
    }
    for (inventory, consumed) |e, hit| {
        if (hit) continue;
        ok = false;
        std.debug.print("원장에 적힌 {s} 를 못 찾았다 — 파일이 사라졌거나 이름이 바뀌었다. 항목을 지워라.\n", .{e.path});
    }
    return ok;
}

/// 원장과 어긋나면 **무엇을 어떻게 고칠지** 말하고 false 를 돌려준다. 두 축(§7.2 번역 대상 ·
/// §7.1 영어 고정)이 같은 규칙을 쓰도록 한 자리에 둔다.
fn reportIfDrifted(path: []const u8, found: usize) bool {
    const expected = lookup(path) orelse 0;
    if (found == expected) return true;

    if (found > expected) {
        std.debug.print(
            \\
            \\{s}: 한국어 리터럴 {d} 개 (원장 {d}) — **늘었다**.
            \\  번역 대상 레이어면(§7.2) `src/i18n.zig` 에 키를 만들고 `i18n.t(.key)` 로 쓴다.
            \\  영어 고정 표면이면(§7.1 — `src/cli`·`src/main.zig`) 그냥 **영어로 적는다**.
            \\  표시가 아니면(진단·로그·fixture) 그 사실을 코드 주석에 적고 원장을 올린다.
            \\  단일 출처: docs/i18n.md §7.
            \\
        , .{ path, found, expected });
    } else {
        std.debug.print(
            \\
            \\{s}: 한국어 리터럴 {d} 개 (원장 {d}) — **줄었다**. 원장을 이 값으로 낮춰라.
            \\  줄어든 것을 통과시키면 원장이 헐거워져 나중에 새 리터럴이 그 여유에 숨는다.
            \\
        , .{ path, found, expected });
    }
    return false;
}

test "번역 대상 레이어의 한국어 리터럴은 원장보다 늘지 않는다" {
    consumed = @splat(false);
    const allocator = std.testing.allocator;
    var failed = false;
    var scanned: usize = 0;

    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            // **심링크도 훑는다.** `.file` 만 받으면 심링크된 `.zig` 가 통째로 안 보인다.
            // **`.zig` 가 아닌 심링크는 실패시킨다.** walker 는 디렉터리 심링크에 안 들어가므로 그 안은
            // **통째로 안 보이고 `scanned` 도 안 올라간다** — 눈이 먼 것을 통과로 읽는 것이다. 앞 판은
            // 심링크된 **파일**만 받아들이고 디렉터리는 그대로 뒀는데, 형제 게이트에는 이 실패 모드를
            // 이미 짜 두었으면서 여기만 반쪽이었다. 조용히 안 보느니 시끄럽게 막는다.
            if (entry.kind == .sym_link and !std.mem.endsWith(u8, entry.basename, ".zig")) {
                std.debug.print(
                    "{s}/{s}: `.zig` 가 아닌 심링크다 — 그 안은 통째로 안 보인다. 실제 디렉터리로 두어라.\n",
                    .{ root, entry.path },
                );
                return error.TestUnexpectedResult;
            }
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });
            // 표 자신은 값을 **정의**한다 — 그것을 위반으로 세면 이 게이트가 늘 빨갛다.
            // **파일 이름이 아니라 경로로** 뺀다. 이름으로 빼면 아무 디렉터리에나 `*i18n.zig` 를 두고
            // 그 안에서 한국어 리터럴을 마음껏 쓸 수 있다(실측으로 통과했다 — 형제 게이트 둘은 같은
            // 결함을 경로 비교로 고쳤는데 이 파일만 남아 있었다).
            if (std.mem.eql(u8, path, table_path)) continue;

            const source = try dir.readFileAllocOptions(
                std.testing.io,
                entry.path,
                allocator,
                .limited(8 * 1024 * 1024),
                .of(u8),
                0,
            );
            defer allocator.free(source);

            scanned += 1;
            if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
        }
    }

    // 뿌리 밖의 표시 문자열 파일(위 `extra_files`). 없어졌으면 **조용히 넘어가지 않는다** — 목록이
    // 실제와 어긋나면 이 게이트가 안 보는 자리를 본다고 거짓말하게 된다.
    for (extra_files) |path| {
        const source = std.Io.Dir.cwd().readFileAllocOptions(
            std.testing.io,
            path,
            allocator,
            .limited(8 * 1024 * 1024),
            .of(u8),
            0,
        ) catch {
            failed = true;
            std.debug.print("표시 문자열 대상 {s} 를 못 찾았다 — 옮겨졌거나 사라졌다. 목록을 고쳐라.\n", .{path});
            continue;
        };
        defer allocator.free(source);
        scanned += 1;
        if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
    }

    // 영어 고정 표면(§7.1)도 같은 원장으로 본다 — 규칙은 다르지만(키가 아니라 영어) **한국어가 늘면
    // 안 된다**는 점이 같고, 한 자리에서 세는 편이 원장을 나누는 것보다 어긋날 여지가 적다.
    for (english_only_roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            // **심링크도 훑는다.** 앞 판은 두 walk 루프 중 **하나만** 고쳤다 — 이쪽(§7.1 이
            // 영어로 고정한 표면)이 남아 심링크로 한국어를 들여올 수 있었다(실측).
            // **`.zig` 가 아닌 심링크는 실패시킨다.** walker 는 디렉터리 심링크에 안 들어가므로 그 안은
            // **통째로 안 보이고 `scanned` 도 안 올라간다** — 눈이 먼 것을 통과로 읽는 것이다. 앞 판은
            // 심링크된 **파일**만 받아들이고 디렉터리는 그대로 뒀는데, 형제 게이트에는 이 실패 모드를
            // 이미 짜 두었으면서 여기만 반쪽이었다. 조용히 안 보느니 시끄럽게 막는다.
            if (entry.kind == .sym_link and !std.mem.endsWith(u8, entry.basename, ".zig")) {
                std.debug.print(
                    "{s}/{s}: `.zig` 가 아닌 심링크다 — 그 안은 통째로 안 보인다. 실제 디렉터리로 두어라.\n",
                    .{ root, entry.path },
                );
                return error.TestUnexpectedResult;
            }
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });
            const source = try dir.readFileAllocOptions(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024), .of(u8), 0);
            defer allocator.free(source);

            scanned += 1;
            if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
        }
    }
    for (english_only_files) |path| {
        const source = std.Io.Dir.cwd().readFileAllocOptions(std.testing.io, path, allocator, .limited(8 * 1024 * 1024), .of(u8), 0) catch continue;
        defer allocator.free(source);
        scanned += 1;
        if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
    }

    // 훑을 파일이 없다면 경로가 바뀐 것이다 — 0 을 통과시키면 "규칙이 지켜진다"와 "아무것도 안 봤다"를
    // 구분할 수 없어진다.
    try std.testing.expect(scanned > 0);
    if (!reportUnconsumed()) failed = true;
    try std.testing.expect(!failed);
}
