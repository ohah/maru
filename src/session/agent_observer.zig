//! 터미널이 이미 소유한 foreground/screen/OSC/activity 관측값으로 대화형 에이전트 상태를 판정한다.
//! provider 설정이나 트랜스크립트를 읽지 않는 OS-중립 순수 코어다. platform은 bounded 화면 문자열만 넘긴다.

const std = @import("std");

pub const Agent = enum { claude, codex };

pub const State = enum { unknown, running, blocked, idle };

pub const Input = struct {
    screen: []const u8 = "",
    osc_title: []const u8 = "",
    osc_progress: []const u8 = "",
    output_active: bool = false,
};

pub const Detection = struct {
    state: State,
    rule_id: []const u8,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_running: bool = false,
    /// 매치했으나 상태를 바꾸지 말라는 규칙(skip_state_update)이 이긴 경우. Stabilizer가 직전 상태를 유지한다.
    skip: bool = false,

    /// 화면·OSC에서 실제로 본 근거가 있는지. 없으면 **약한 신호**이며(현재는 PTY activity 폴백 하나) 근거 있는
    /// 직전 상태를 즉시 덮지 못한다. 단일 출처는 docs/agent-session.md «상태 모델과 우선순위» 신호 세기 중재.
    pub fn hasVisibleEvidence(self: Detection) bool {
        return self.visible_idle or self.visible_blocker or self.visible_running;
    }
};

/// 화면 tail을 평면 하단 N행 대신 구조 region으로 나눈다. `screen`은 기존 whole tail이고, 나머지는 프롬프트
/// 마커·수평선을 앵커로 순수 문자열 슬라이싱해 얻는다(할당·정규식 없음). title/progress는 OSC 입력에서 온다.
/// 규칙 데이터의 실제 이관은 후속(규칙 이관 PR)이며, 이 파일은 엔진만 추가하고 기존 규칙/판정은 그대로 둔다.
const Region = enum { screen, title, progress, prompt_anchor, box_body, output, footer };

fn isScreenRegion(region: Region) bool {
    return switch (region) {
        .title, .progress => false,
        else => true,
    };
}

/// 재귀 불리언 게이트. leaf는 `contains`(대소문자 무시)·`line_prefix`이고 `all`(AND)/`any`(OR)/`not`(NAND)로
/// 중첩한다. comptime 데이터라 힙이 없다. 기존 평면 `all/any/none`은 이 게이트의 단층 특수형이다.
const Gate = struct {
    contains: []const []const u8 = &.{},
    line_prefix: []const []const u8 = &.{},
    /// 앞 공백을 벗긴 첫 코드포인트가 이 범위 중 하나(OR)에 드는 라인이 있는지.
    leading_codepoint_ranges: []const CodepointRange = &.{},
    /// **같은 한 줄** 안에서 prefix와 모든 contains를 동시에 만족하는 라인이 있는지. 평면 `contains`는 화면 전체를
    /// 훑어 서로 다른 줄의 조각을 조합해 버리므로, chrome 한 줄의 모양을 지정할 때는 이 leaf를 쓴다 — 에이전트가
    /// 그 문구를 여러 줄에 흩어 언급하는 산문과 실제 chrome 한 줄을 구분하는 유일한 수단이다.
    line: ?LineMatch = null,
    all: []const Gate = &.{},
    any: []const Gate = &.{},
    not: []const Gate = &.{},
};

/// 한 줄 안의 모양. `prefix`는 앞 공백(과 박스 세로선)을 벗긴 뒤 비교하고, `contains`는 그 줄 안에서 대소문자 무시
/// 부분일치를 **모두** 요구한다. 둘 다 비면 양성 매처가 없으므로 빌드에서 거부한다(validateGate).
const LineMatch = struct {
    prefix: []const u8 = "",
    contains: []const []const u8 = &.{},
};

/// 빌드에 포함되는 작은 manifest 행. v1은 정규식 엔진 없이 문자열 조건·구조 region만 쓴다.
const Rule = struct {
    id: []const u8,
    state: State,
    priority: u16,
    region: Region,
    all: []const []const u8 = &.{},
    any: []const []const u8 = &.{},
    none: []const []const u8 = &.{},
    line_prefixes: []const []const u8 = &.{},
    /// 앞 공백을 벗긴 첫 코드포인트가 이 범위 중 하나(OR)에 드는 라인이 있는지. 스피너처럼 프레임 집합이
    /// 버전마다 달라지는 신호를 개별 문자 열거 없이 블록 범위로 판정한다(정규식 엔진 불필요).
    leading_codepoint_ranges: []const CodepointRange = &.{},
    /// 설정되면 평면 all/any/none 대신 이 게이트로 판정한다(중첩 조건용).
    gate: ?Gate = null,
    /// **일시적 오버레이 규칙 전용** 거리 게이트. 권한 확인·중단 배너처럼 스크롤되는 출력 문구는 위로 밀린 뒤에는
    /// 현재 근거가 아니므로 하단 거리로 유효 범위를 제한한다. 반대로 입력 프롬프트·실행 footer 같은 **상시 chrome**에는
    /// 걸지 않는다 — 사용자 입력이 길어지면 chrome이 스스로 밀려나 근거가 사라지기 때문이다(실측).
    max_lines_from_bottom: ?u8 = null,

    /// **위치 비교를 건너뛰고 priority 로 겨룬다.** `ruleBetter` 는 「같은 화면의 idle/running 충돌은 더
    /// 아래에 보이는 증거가 이긴다」로 정하는데, 그 가정은 **상태줄이 입력창 아래**라는 레이아웃에 묶여
    /// 있다. claude 2.1.25x 는 진행 상태줄(`✽ Mulling… `)을 **입력창 `❯` 위**에 그려서(실측 2026-09-05:
    /// 스피너 10 행 · 프롬프트 13 행) 그 가정이 깨진다 — running 이 위치에서 지고 화면이 idle 로 판정된다.
    ///
    /// ⚠️ **「현재 chrome 으로 식별된 신호」에만 준다.** 대화 출력에 남은 옛 `Working…` 텍스트까지 이 예외를
    /// 받으면 「낡은 footer 아래 새 프롬프트는 idle」 계약이 깨진다(그 판정자가 이 저장소에 있다). 그래서
    /// 이 예외를 쓰는 규칙은 **스피너 prefix + `…`** 처럼 chrome 자체를 지목하는 게이트를 함께 든다.
    beats_position: bool = false,
    /// 매치돼도 상태를 바꾸지 않고 직전 상태를 유지한다(전이·로딩 중간 화면 오탐 억제). state는 unknown이어야 한다.
    skip_state_update: bool = false,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_running: bool = false,
};

/// 코드포인트 범위 조건. 정규식 엔진 없이 UTF-8 첫 코드포인트를 정수 비교만으로 판정한다.
const CodepointRange = struct { lo: u21, hi: u21 };

/// 브라유 점자 블록 전체. 에이전트 작업 스피너는 이 블록의 임의 프레임을 쓰고 버전마다 프레임 집합이 달라지므로
/// (실측: claude 2.1.218 OSC 타이틀은 U+2810·U+2802를 쓰는데, 과거 열거하던 10프레임과 교집합이 0이었다)
/// 개별 프레임을 열거하지 않고 블록 범위로 판정해 프레임 변경에 견디게 한다.
const braille_block = CodepointRange{ .lo = 0x2800, .hi = 0x28FF };

/// 반원 스피너 블록(◐◓◑◒ = U+25D0~U+25D3). **claude 2.1.228 실측**: running OSC 타이틀 선두가 `◐`(U+25D0)·
/// `◑`(U+25D1)를 교대로 쓴다(0.35초 간격 14회 표본에서 두 프레임만 관측 — `maru sessions list`로 실행 중 세션의
/// 타이틀을 직접 읽었다). 위 브라유 범위와 **교집합이 0**이라, braille만 보던 `working_title`이 통째로 불발하고
/// composer의 `❯`가 `live_prompt`(idle)로 이겨 **작업 중 세션이 "대기중"으로 표시됐다**(사용자 보고 2026-08-12).
///
/// **브라유를 지우지 않고 둘 다 인정한다**(사용자 결정): 어느 버전에서 계열이 바뀌었는지 특정하지 못했고
/// (2.1.226·227·228 바이너리 모두 두 문자를 평문으로 품고 있어 평문 검색으로는 가려지지 않는다), 구버전으로
/// 롤백하거나 다른 provider가 브라유를 쓰는 경우 그쪽이 다시 깨진다. 관측된 두 계열을 함께 두는 것이
/// "프레임 변경에 견딘다"는 위 규율의 연장이다. 관측되지 않은 계열은 넣지 않는다.
///
/// codex는 **건드리지 않았다** — 같은 취약성이 있지만 codex 타이틀은 이 보고 시점에도 정상 판정됐고(사용자 확인),
/// 실측 없이 범위를 넓히면 근거 없는 데이터가 된다(docs/agent-session.md «실측 신호 기록»).
const half_circle_block = CodepointRange{ .lo = 0x25D0, .hi = 0x25D3 };

const claude_rules = [_]Rule{
    // `any`의 선택지는 **선택지 줄의 실측 모양**(`❯ 1. Yes…`)을 쓴다. 맨 단어 `yes`는 화면 어디에나 있어서, 위쪽 산문의
    // `Do you want to proceed?`와 아래 composer에 사용자가 친 `yes …`가 조합돼 거짓 blocked를 만들었다(코드 리뷰에서
    // 재현). 거리 게이트가 근거 전체(가장 위 근거)를 재게 바뀌었으므로 이제 두 근거가 떨어져 있으면 통과하지 못한다.
    //
    // 거리 상한 10의 근거는 실측이다(claude 2.1.x, 100×30). 권한 다이얼로그는 composer·statusLine을 **대체**하고 마지막
    // 줄이 `Esc to cancel · Tab to amend · …` 힌트다. 옵션 3개일 때 `Do you want to proceed?`가 하단에서 5행이고 옵션이
    // 하나 늘 때마다 1행씩 밀리므로, 6으로 두면 옵션 4개부터 다이얼로그를 놓친다. 10이면 옵션 8개까지 덮는다.
    .{ .id = "permission_prompt", .state = .blocked, .priority = 1000, .region = .screen, .all = &.{"do you want to proceed?"}, .any = &.{ "esc to cancel", "1. yes", "tab to amend" }, .max_lines_from_bottom = 10, .visible_blocker = true },
    // 플랜 승인 화면(실측 claude 2.1.226). 위 `permission_prompt`가 요구하는 `Do you want to proceed?`가 **없고**
    // (`Would you like to proceed?`를 쓴다) `Esc to cancel`·`Enter to confirm`·`Enter to select` 힌트도 하나도 없어서,
    // 기존 blocker 세 규칙이 전부 미스했다. 그 상태에서 OSC 타이틀의 `✳`가 `idle_title`로 이겨 **승인 대기가 유휴로**
    // 표시됐다(사용자 리포트 경로: 사이드바 카드·워크스페이스 대표 상태까지 유휴).
    //
    // region이 `.footer`인 것이 이 규칙의 핵심이다. 승인 화면은 composer를 **대체**해 프롬프트 줄이 없으므로 footer가
    // "마지막 수평선 아래 전부"로 열려 승인 UI 블록을 정확히 덮는다. 반대로 평소 화면에는 composer 프롬프트가 있어
    // footer가 상태줄만 되므로, 같은 문구가 **대화 본문이나 composer 입력에 있으면 애초에 region 밖**이라 매치하지
    // 않는다. `.screen`으로 두면 사용자가 그 문구를 타이핑하거나 모델이 답변에서 언급할 때 거짓 blocked가 섰다(재현).
    //
    // 앵커를 여럿 둔 이유는 **wrap 내성**이다. 좁은 창에서는 안내 문장이 줄바꿈되어 조각난다(실측 72칸에서
    // `… Would you` / `like to proceed?`로 끊겼다). 옵션 라벨처럼 짧은 앵커가 함께 있어야 45칸급에서도 하나는 살아남는다.
    // `all`+`any` 조합이 아니라 **단독 매치되는 `any`**라 떨어진 조각이 조합돼 오탐을 만들지 않는다.
    .{ .id = "plan_approval", .state = .blocked, .priority = 1000, .region = .footer, .any = &.{ "written up a plan and is ready", "would you like to proceed?", "tell claude what to change", "no, keep planning", "shift+tab to approve" }, .visible_blocker = true },
    // 도구 권한 다이얼로그의 본문 질문은 도구마다 달라진다(실측: `Do you want to create hello.txt?` — `proceed?`가 아니다).
    // 그래서 질문 문구가 아니라 **고정 footer 힌트**(`Esc to cancel · Tab to amend`)로 집는다. 위 `permission_prompt`는
    // `proceed?` 화면만 덮으므로 이 규칙이 나머지 도구를 덮는다(둘 다 blocker라 어느 쪽이 이겨도 결과는 같다).
    .{ .id = "permission_footer", .state = .blocked, .priority = 999, .region = .footer, .all = &.{ "esc to cancel", "tab to amend" }, .visible_blocker = true },
    .{ .id = "selection_prompt", .state = .blocked, .priority = 990, .region = .screen, .all = &.{ "enter to select", "esc to cancel" }, .max_lines_from_bottom = 10, .visible_blocker = true },
    // 폴더 신뢰 확인 등 확정형 선택 화면(실측: `❯ 1. Yes…` + `Enter to confirm · Esc to cancel`).
    .{ .id = "confirm_prompt", .state = .blocked, .priority = 985, .region = .screen, .all = &.{ "enter to confirm", "esc to cancel" }, .max_lines_from_bottom = 10, .visible_blocker = true },
    // 입력 줄은 하단 거리가 아니라 구조로 집는다. 사용자 statusLine 커스텀이 상태줄을 여러 줄로 만들면 거리
    // 가드가 현재 프롬프트를 잔상으로 오인하므로(실측), prompt_anchor가 프롬프트 라인 자체를 앵커로 쓴다.
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .prompt_anchor, .line_prefixes = &.{"❯"}, .visible_idle = true },
    .{ .id = "idle_title", .state = .idle, .priority = 880, .region = .title, .any = &.{"✳"}, .visible_idle = true },
    // OSC 9;4(ConEmu progress)는 실측에서 두 provider 모두 emit하지 않았다 — 현재 발화하지 않는 규칙이다.
    // 표준 기반 데이터라 존치하되 근거 있는 값으로 오해하지 않도록 남긴다(docs/agent-session.md «실측 신호 기록»).
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    // 작업 중에도 composer가 열려 있어 live_prompt와 동시에 매치되므로 idle보다 우선한다(실측).
    .{ .id = "working_title", .state = .running, .priority = 950, .region = .title, .leading_codepoint_ranges = &.{ braille_block, half_circle_block }, .visible_running = true },
    // 실행 footer도 상시 chrome이라 거리 게이트를 걸지 않는다. 사용자 statusLine이 여러 줄이거나 입력이 여러 행이면
    // footer가 스스로 위로 밀려 근거가 사라지고, 그 화면에는 idle 근거도 없어 판정이 폴백으로 떨어진다(실측).
    //
    // 대신 region을 `footer`(프롬프트 박스 **아래**)로 좁힌다. `screen`으로 두면 사용자가 composer 본문에 그 문구를
    // 타이핑하는 것만으로 위치 tiebreak가 footer 손을 들어 준다 — live_prompt의 위치는 프롬프트 **라인 시작** offset인데
    // 본문에 있는 문구는 그보다 아래(큰 offset)라서 항상 이긴다(코드 리뷰에서 재현). 구조로 자르면 입력 본문은
    // box_body이고 실행 chrome만 footer라 그 조합이 성립하지 않는다.
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .footer, .any = &.{ "esc to interrupt", "esc to stop" }, .visible_running = true },
    // **진행 상태줄이 입력창 위에 있다** — 그래서 위치 비교로는 `live_prompt` 에 진다(`beats_position`).
    // `working_footer` 가 찾는 `esc to interrupt` 는 2.1.25x 화면에 더 이상 없고(실측 2026-09-05),
    // tmux 안에서는 OSC 제목도 흡수되어 `working_title` 까지 죽으므로, 이 규칙이 없으면 running 근거가
    // **하나도** 남지 않아 권위표 C2 가 훅의 running 을 뒤집는다.
    .{ .id = "working_spinner", .state = .running, .priority = 905, .region = .screen, .visible_running = true, .beats_position = true, .gate = .{ .any = &claude_working_gates } },
};

/// codex turn 진행의 단일 discriminator: 실행 footer **한 줄**의 모양이다(실측 `• Working (3s • esc to interrupt)`).
/// 한 줄 안에서 판정하는 이유는 두 가지 오탐을 동시에 막기 위함이다. ⑴ 평면 `all`로 두면 화면 전체에서 `working`과
/// `esc to interrupt`를 **서로 다른 줄에서** 주워 조합한다. ⑵ 문구를 `esc to interrupt)`처럼 붙여 쓰면 footer 뒤에
/// 다른 항목이 붙거나 wrap으로 `)`가 다음 줄로 밀릴 때 매치가 사라지고, 그 순간 아래 live_prompt가 **근거 있는 idle**을
/// 세워 작업 중인 세션이 "대기중"으로 보인다(코드 리뷰에서 재현). 불릿 prefix까지 요구해 산문 인용도 대부분 걸러 낸다 —
/// codex 출력 불릿도 `•`를 쓰므로 완벽한 분리는 아니고, 그 잔여는 docs «한계»에 적었다.
/// claude 진행 상태줄. **`esc to interrupt` 는 더 이상 화면에 안 나온다**(2.1.251~2.1.260 실측 2026-09-05):
/// 진행 중에는 `✽ Mulling… `, 끝나면 같은 자리가 `✻ Worked for 26s · done 오후 3:41` 이다 —
/// **`…`(U+2026) 유무가 그 둘을 가른다**(7 pane × 30 회 관측: 진행 줄은 전부 `…`, 완료 줄은 하나도 없음).
///
/// **스피너 프레임은 회전한다.** 아래 다섯은 전부 실측이다(10 pane × 150 회, 2026-09-05):
/// `✽`(U+273D) 101 · `✢`(U+2722) 86 · `✻`(U+273B) 77 · `✶`(U+2736) 72 · `✳`(U+2733) 62 회.
/// `LineMatch` 는 문자열 prefix 만 받으므로(codepoint 대역은 **같은 줄 보장이 없다**) 나열한다.
///
/// ⚠️ **추정으로 늘리지 않는다.** 같은 Dingbats 계열이라는 이유로 `✷✸✹✺✴` 를 넣었다가 뺐다 —
/// 같은 관측에서 **한 번도 안 나왔고**, 근거 없는 prefix 는 오탐만 늘린다. claude 답변 블록 마커
/// `⏺`(U+23FA, 같은 관측에서 155 회로 최다)가 그 위험을 그대로 보여 준다: **완료된 답변 줄이 화면에
/// 계속 남으므로**, 그 줄에 `…` 가 있으면(실측: %27 은 3 줄 중 1 줄, %16 은 13 줄 중 1 줄) 배지가
/// 영영 running 에 묶인다. 그래서 `⏺` 는 **일부러 뺐다.**
///
/// 목록에 없는 프레임이 오면 이 규칙이 조용히 안 걸린다. 그때는 `MARU_DEBUG` 의 `screen_rule=` 이
/// 무엇이 걸렸는지 알려 주므로(계약 §1.7) 거기서 새 프레임을 확인해 **실측으로** 더한다.
const claude_spinner_frames = [_][]const u8{ "✻", "✽", "✢", "✳", "✶" };

/// 프레임마다 «그 기호로 시작하고 `…` 를 포함하는 **한 줄**» 을 요구한다. `Gate.line` 만이 같은 줄을
/// 보장한다 — 평면 `contains` 로 쓰면 대화 출력의 `…` 가 진행 신호로 둔갑한다.
const claude_working_gates = blk: {
    var g: [claude_spinner_frames.len]Gate = undefined;
    for (claude_spinner_frames, 0..) |frame, i| {
        g[i] = .{ .line = .{ .prefix = frame, .contains = &.{"…"} } };
    }
    break :blk g;
};


const codex_working_line = LineMatch{ .prefix = "•", .contains = &.{ "working", "esc to interrupt" } };

const codex_rules = [_]Rule{
    .{ .id = "action_required_title", .state = .blocked, .priority = 1000, .region = .title, .all = &.{"action required"}, .visible_blocker = true },
    // 확인 문구가 **composer에 타이핑된 경우**는 근거로 치지 않는다. codex 승인 화면은 composer를 대체하므로 정상
    // 승인 화면에는 `›` 입력 줄이 아예 없다(실측 0.146.1 — 옵션 줄만 `›`를 쓰고 확인 문구는 그 아래 별도 줄이다).
    // 반대로 사용자가 그 문구를 입력 줄에 치면(승인 UI 문구를 다루는 작업에서 실제로 일어난다) `screen` region +
    // 하단 6줄 게이트에 그대로 걸려 거짓 blocked가 섰다 — 작업 중인 세션이 "입력 대기"로 뒤집히고 blocked는 절대
    // 우선이라 워크스페이스 대표 상태까지 오염된다.
    //
    // claude와 좁히기 수단이 다른 이유는 «상태 모델과 우선순위»가 적은 그대로다. codex composer는 박스 테두리 없이
    // 프롬프트 아래 상태줄이 상수로 붙는 구조라 `footer`/`prompt_anchor` region이 성립하지 않으므로, 구조 region이
    // 아니라 **한 줄의 모양**(`›`로 시작하는 줄에 확인 문구가 있는가)으로 배제한다. `not`이라 정상 승인 화면
    // (그런 줄이 없음)은 그대로 통과한다.
    .{
        .id = "confirmation_prompt",
        .state = .blocked,
        .priority = 990,
        .region = .screen,
        .max_lines_from_bottom = 6,
        .visible_blocker = true,
        .gate = .{
            .any = &.{
                .{ .contains = &.{"press enter to confirm or esc to cancel"} },
                .{ .contains = &.{"press enter to confirm or esc to go back"} },
                .{ .contains = &.{"press enter to continue"} },
                .{ .contains = &.{"allow command?"} },
                .{ .contains = &.{"enter to submit answer"} },
                .{ .contains = &.{"enter to submit all"} },
            },
            // `enter to`·`allow command?`는 위 여섯 문구를 모두 덮는 최소 공통 조각이다. composer 한 줄에 이 조각이
            // 있으면 그 화면은 승인 대기가 아니라 사용자가 타이핑 중인 화면이다.
            .not = &.{.{ .any = &.{
                .{ .line = .{ .prefix = "›", .contains = &.{"enter to"} } },
                .{ .line = .{ .prefix = "›", .contains = &.{"allow command?"} } },
            } }},
        },
    },
    .{ .id = "interrupted_prompt", .state = .idle, .priority = 885, .region = .screen, .all = &.{"conversation interrupted"}, .max_lines_from_bottom = 4, .visible_idle = true },
    // Codex는 turn 실행 중에도 아래 composer를 열어 steering 입력을 받는다. 따라서 prompt가 더 아래에 있어도
    // 실행 footer가 현재 tail에 함께 보이면 idle 근거가 아니다. 즉 codex에서는 "아래=최신" tiebreak가 성립하지 않고
    // footer 한 줄(`codex_working_line`)이 turn 진행의 discriminator다.
    //
    // 하단 거리 게이트는 뺐다. codex composer는 박스 테두리 없이 `› 입력` + 빈 행 + `Context …` 상태줄(상수 2행)
    // 구조라(실측 0.146.0), 입력이 4행이 되면 마커의 하단 거리가 5가 되어 **유일한 idle 근거가 사라진다.** 그러면
    // pty_activity 폴백만 남아 타이핑 에코가 running으로 단정됐다(사용자 보고 증상). 프롬프트 아래에 상태줄이 상수로
    // 붙어서 `prompt_anchor`("마커 아래가 모두 공백") 정의에도 걸리지 않으므로 region 이관 대신 `screen`을 유지한다.
    //
    // `allow command?`는 `not`에서 뺐다. 승인 화면은 confirmation_prompt(blocker)가 절대 우선으로 이미 이기므로 중복인데,
    // tail이 넓어지면 **이미 승인이 끝난 오래된 문구**가 유일한 idle 근거를 지워 폴백이 타이핑을 running으로 만든다
    // (코드 리뷰에서 재현). blocker 쪽은 거리 게이트로 현재성을 보고, idle 쪽은 그 문구를 아예 보지 않는다.
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .visible_idle = true, .gate = .{
        .any = &.{ .{ .line_prefix = &.{"›"} }, .{ .line_prefix = &.{"❯"} } },
        .not = &.{.{ .line = codex_working_line }},
    } },
    // OSC 9;4(ConEmu progress)는 실측에서 두 provider 모두 emit하지 않았다 — 현재 발화하지 않는 규칙이다.
    // 표준 기반 데이터라 존치하되 근거 있는 값으로 오해하지 않도록 남긴다(docs/agent-session.md «실측 신호 기록»).
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 950, .region = .title, .leading_codepoint_ranges = &.{braille_block}, .visible_running = true },
    // live_prompt의 `not`과 **같은 게이트**를 쓴다. 한쪽만 좁으면 provider가 문구를 바꿀 때 "프롬프트도 아니고 실행도
    // 아닌" 화면이 생겨 근거 공백이 나고, 폴백이 그 틈을 메우며 오판한다. 같은 discriminator를 공유하면 두 규칙이
    // 구성상 상호배타가 되어 공백이 없다. 거리 게이트를 뺀 이유는 실측 배치에서 footer가 live composer **위**에 와서
    // (에코 → footer → steering composer → 상태줄) 하단 거리가 6이 되고, 그러면 **실제 작업 중에도** running 근거가
    // 사라지기 때문이다(반대 방향 결함).
    //
    // claude는 프롬프트가 항상 실행 chrome보다 위라 region(`footer`)으로 자를 수 있지만, codex는 실행 표시가 프롬프트
    // **위**에 와서 그 구조가 성립하지 않는다. 그래서 codex는 region 대신 **한 줄 모양**으로 좁힌다.
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .visible_running = true, .gate = .{ .line = codex_working_line } },
};

pub fn detect(agent: Agent, input: Input) Detection {
    const rules: []const Rule = switch (agent) {
        .claude => &claude_rules,
        .codex => &codex_rules,
    };
    return detectWithRules(rules, input);
}

/// 규칙 집합을 주입해 판정한다. 프로덕션 detect()는 provider별 하드코딩 규칙을 넘기고, 테스트는 합성 규칙으로
/// region/게이트/skip 엔진을 격리 검증한다.
fn detectWithRules(rules: []const Rule, input: Input) Detection {
    const lines = scanLines(input.screen);
    var best: ?Rule = null;
    var best_position: usize = 0;
    for (rules) |rule| {
        const match_position = matchPosition(rule, input, &lines) orelse continue;
        if (best == null or ruleBetter(rule, match_position, best.?, best_position)) {
            best = rule;
            best_position = match_position;
        }
    }
    if (best) |rule| return .{
        .state = rule.state,
        .rule_id = rule.id,
        .visible_idle = rule.visible_idle,
        .visible_blocker = rule.visible_blocker,
        .visible_running = rule.visible_running,
        .skip = rule.skip_state_update,
    };
    if (input.output_active) return .{ .state = .running, .rule_id = "pty_activity" };
    return .{ .state = .unknown, .rule_id = "no_match" };
}

fn ruleBetter(candidate: Rule, candidate_position: usize, current: Rule, current_position: usize) bool {
    // 입력을 막는 현재 prompt는 다른 신호보다 항상 우선한다. 그 외 같은 화면의 idle/running 충돌은
    // 고정 priority가 아니라 더 아래(더 최신 chrome)에 보이는 증거가 이긴다. 위치는 full-screen offset 기준이라
    // 구조 region(footer/box_body 등) 규칙과 whole tail 규칙을 함께 비교할 수 있다.
    if (candidate.visible_blocker != current.visible_blocker) return candidate.visible_blocker;
    // **현재 chrome 으로 식별된 신호는 위치를 건너뛴다**(`beats_position`) — 아래 위치 규칙은 상태줄이
    // 입력창 아래라는 레이아웃 가정이라, 위에 그리는 provider 에서 running 이 부당하게 진다.
    if (candidate.beats_position != current.beats_position) return candidate.beats_position;
    if (isScreenRegion(candidate.region) and isScreenRegion(current.region) and candidate_position != current_position) {
        return candidate_position > current_position;
    }
    return candidate.priority > current.priority;
}

fn matchPosition(rule: Rule, input: Input, lines: *const LineScan) ?usize {
    var haystack: []const u8 = "";
    var base: usize = 0;
    switch (rule.region) {
        .title => haystack = input.osc_title,
        .progress => haystack = input.osc_progress,
        else => {
            const slice = regionSliceScanned(lines, rule.region);
            haystack = slice.text;
            base = slice.offset;
        },
    }
    if (rule.gate) |g| {
        // 평면 조건과 같은 의미의 위치(근거가 실제로 보이는 자리)를 쓴다. region 끝을 쓰면 게이트 규칙이
        // 위치 tiebreak에서 항상 이겨 "더 아래가 최신"이라는 의미가 깨진다.
        //
        // 거리 게이트도 평면 경로와 **같은 의미**로 적용한다(가장 위 근거 기준). 예전에는 게이트 규칙이면 여기서
        // 곧바로 반환해 `max_lines_from_bottom`이 조용히 무시됐다 — 데이터에 값을 적어도 동작하지 않는 함정이라,
        // 게이트로 옮기는 것만으로 오버레이 규칙이 현재성을 잃는다(실제로 `confirmation_prompt` 이관에서 재현).
        const span = gateMatchSpan(g, haystack) orelse return null;
        if (tooFarFromBottom(rule, haystack, span.earliest)) return null;
        return base + span.latest;
    }
    var latest: usize = 0;
    // 거리 게이트는 **가장 위 근거**를 기준으로 잰다. 가장 아래 근거만 보면 조건이 여럿인 규칙이 20행 떨어진 조각을
    // 조합해도 통과해, 위쪽 산문 + 아래쪽 사용자 입력으로 거짓 blocked가 섰다(코드 리뷰에서 재현). 오버레이 문구는
    // 실제로 붙어 있으므로 "근거 전체가 하단 N행 안"이 원래 의도다.
    var earliest: ?usize = null;
    for (rule.all) |needle| {
        const pos = lastIndexOfIgnoreCase(haystack, needle) orelse return null;
        latest = @max(latest, pos);
        earliest = @min(earliest orelse pos, pos);
    }
    if (rule.any.len > 0) {
        var found: ?usize = null;
        for (rule.any) |needle| if (lastIndexOfIgnoreCase(haystack, needle)) |pos| {
            found = @max(found orelse 0, pos);
        };
        const pos = found orelse return null;
        latest = @max(latest, pos);
        earliest = @min(earliest orelse pos, pos);
    }
    for (rule.none) |needle| if (containsIgnoreCase(haystack, needle)) return null;
    if (rule.line_prefixes.len > 0) {
        const pos = lastLinePrefixPosition(haystack, rule.line_prefixes) orelse return null;
        latest = @max(latest, pos);
        earliest = @min(earliest orelse pos, pos);
    }
    if (rule.leading_codepoint_ranges.len > 0) {
        const pos = lastLeadingCodepointPosition(haystack, rule.leading_codepoint_ranges) orelse return null;
        latest = @max(latest, pos);
        earliest = @min(earliest orelse pos, pos);
    }
    const anchor = earliest orelse return null;
    if (tooFarFromBottom(rule, haystack, anchor)) return null;
    return base + latest;
}

/// 거리 게이트 판정(평면·게이트 경로 공용 단일 출처). `anchor`는 **가장 위 근거**의 offset이다 — 가장 아래만
/// 재면 조건이 여럿인 규칙이 멀리 떨어진 조각을 조합해도 통과한다(위 주석의 재현 사례).
fn tooFarFromBottom(rule: Rule, haystack: []const u8, anchor: usize) bool {
    const max_lines = rule.max_lines_from_bottom orelse return false;
    var lines_after: usize = 0;
    for (haystack[anchor..]) |byte| if (byte == '\n') {
        lines_after += 1;
    };
    return lines_after >= max_lines;
}

/// 게이트 근거가 차지한 구간. `latest`(가장 아래)는 위치 tiebreak에, `earliest`(가장 위)는 거리 게이트에 쓴다 —
/// 평면 조건이 `latest`/`earliest`를 각각 그 두 곳에 쓰는 것과 **같은 의미**다. 하나만 두면 게이트로 옮긴 규칙이
/// 조용히 다른 의미가 된다.
const GateSpan = struct {
    earliest: usize,
    latest: usize,

    fn absorb(self: *GateSpan, pos: usize, seen: *bool) void {
        self.earliest = if (seen.*) @min(self.earliest, pos) else pos;
        self.latest = if (seen.*) @max(self.latest, pos) else pos;
        seen.* = true;
    }
};

/// 게이트가 매치하면 **근거가 차지한 구간**(region 안 byte offset)을 돌려준다. 여러 근거가 맞으면 tiebreak는 가장
/// 아래(가장 최신 chrome), 거리 게이트는 가장 위를 본다 — 평면 조건의 의미와 같게 맞춰, 게이트 규칙도 같은
/// tiebreak·현재성 규칙을 따르게 한다.
/// 양성 근거가 하나도 없는 게이트는 매치로 치지 않는다(빌드 검증 `validateGate`가 1차 방어, 이건 2차).
fn gateMatchSpan(gate: Gate, text: []const u8) ?GateSpan {
    var span = GateSpan{ .earliest = 0, .latest = 0 };
    var positive = false;
    for (gate.contains) |needle| {
        span.absorb(lastIndexOfIgnoreCase(text, needle) orelse return null, &positive);
    }
    for (gate.line_prefix) |prefix| {
        const single = [_][]const u8{prefix};
        span.absorb(lastLinePrefixPosition(text, &single) orelse return null, &positive);
    }
    if (gate.leading_codepoint_ranges.len > 0) {
        span.absorb(lastLeadingCodepointPosition(text, gate.leading_codepoint_ranges) orelse return null, &positive);
    }
    if (gate.line) |line| {
        span.absorb(lastLineMatchPosition(text, line) orelse return null, &positive);
    }
    for (gate.all) |sub| {
        const sub_span = gateMatchSpan(sub, text) orelse return null;
        span.absorb(sub_span.earliest, &positive);
        span.absorb(sub_span.latest, &positive);
    }
    if (gate.any.len > 0) {
        // any는 하나만 성립하면 되므로 **가장 아래로 성립한 하나**의 위치를 근거로 쓴다(평면 `any`와 같다).
        // 성립하지 않은 다른 항목의 위치까지 구간에 넣으면 거리 게이트가 엉뚱하게 넓어진다.
        var best: ?usize = null;
        for (gate.any) |sub| if (gateMatchSpan(sub, text)) |sub_span| {
            best = @max(best orelse 0, sub_span.latest);
        };
        span.absorb(best orelse return null, &positive);
    }
    for (gate.not) |sub| if (gateMatchSpan(sub, text) != null) return null;
    if (!positive) return null;
    return span;
}

/// 양성 매처가 없는 게이트는 모든 텍스트에 매치되어 규칙이 조용히 전역 발화한다. 데이터 실수를 런타임이 아니라
/// **빌드에서** 잡는다. `not` 안의 게이트도 같은 이유로 양성 매처가 있어야 한다(비면 항상 매치되어 규칙이 죽는다).
fn gateHasPositiveMatcher(gate: Gate) bool {
    const line_positive = if (gate.line) |line| line.prefix.len > 0 or line.contains.len > 0 else false;
    return gate.contains.len > 0 or gate.line_prefix.len > 0 or
        gate.leading_codepoint_ranges.len > 0 or line_positive or gate.all.len > 0 or gate.any.len > 0;
}

fn validateGate(comptime gate: Gate, comptime rule_id: []const u8) void {
    if (!gateHasPositiveMatcher(gate)) @compileError("agent_observer rule '" ++ rule_id ++ "': 게이트에 양성 매처가 없습니다");
    for (gate.all) |sub| validateGate(sub, rule_id);
    for (gate.any) |sub| validateGate(sub, rule_id);
    for (gate.not) |sub| validateGate(sub, rule_id);
}

/// 상태를 세우는 규칙은 반드시 `visible_*` 근거 플래그를 하나 이상 든다. Stabilizer의 신호 세기 중재가
/// "근거 없는 상태 = 약한 신호"로 판정하므로, 플래그를 빠뜨린 규칙은 조용히 약한 신호로 강등돼 근거 있는 직전
/// 상태를 못 이긴다. 그런 데이터 실수를 런타임이 아니라 **빌드에서** 잡아, 약한 신호 생산자를 PTY activity 폴백
/// 하나로 못박는다. `skip_state_update`는 상태를 세우지 않으므로 반대로 근거 플래그가 없어야 한다.
fn validateRuleEvidence(comptime rule: Rule) void {
    const flagged = rule.visible_idle or rule.visible_blocker or rule.visible_running;
    if (rule.skip_state_update) {
        if (rule.state != .unknown or flagged)
            @compileError("agent_observer rule '" ++ rule.id ++ "': skip 규칙은 state=unknown이고 visible_* 플래그가 없어야 합니다");
        return;
    }
    if (rule.state != .unknown and !flagged)
        @compileError("agent_observer rule '" ++ rule.id ++ "': 상태를 세우는 규칙은 visible_* 근거 플래그가 있어야 합니다");
}

comptime {
    for (claude_rules) |rule| {
        if (rule.gate) |g| validateGate(g, rule.id);
        validateRuleEvidence(rule);
    }
    for (codex_rules) |rule| {
        if (rule.gate) |g| validateGate(g, rule.id);
        validateRuleEvidence(rule);
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    var offset: usize = 0;
    var latest: ?usize = null;
    while (offset <= haystack.len) {
        const relative = std.ascii.indexOfIgnoreCase(haystack[offset..], needle) orelse break;
        latest = offset + relative;
        offset += relative + @max(needle.len, 1);
    }
    return latest;
}

fn firstCodepoint(text: []const u8) ?u21 {
    var view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    return it.nextCodepoint();
}

/// 앞 공백을 벗긴 첫 코드포인트가 주어진 범위 중 하나에 드는 라인 가운데 가장 아래 위치. 범위끼리는 OR이며
/// 정규식 엔진 없이 정수 비교만 한다.
fn lastLeadingCodepointPosition(text: []const u8, ranges: []const CodepointRange) ?usize {
    var position: usize = 0;
    var latest: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimStart(u8, line_raw, " \t\r");
        const indent = line_raw.len - line.len;
        if (firstCodepoint(line)) |cp| {
            for (ranges) |range| {
                if (cp >= range.lo and cp <= range.hi) {
                    latest = position + indent;
                    break;
                }
            }
        }
        position += line_raw.len + 1;
    }
    return latest;
}

/// 같은 한 줄 안에서 prefix와 모든 contains를 만족하는 라인 가운데 가장 아래 위치. 평면 `contains`가 서로 다른 줄의
/// 조각을 조합해 오탐하는 것을 막는 유일한 leaf다(리뷰에서 실제 오탐 4건이 모두 이 조합에서 나왔다).
fn lastLineMatchPosition(text: []const u8, match: LineMatch) ?usize {
    var position: usize = 0;
    var latest: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| : (position += line_raw.len + 1) {
        const line = std.mem.trimStart(u8, line_raw, " \t\r");
        const indent = line_raw.len - line.len;
        if (match.prefix.len > 0 and !std.mem.startsWith(u8, promptContent(line), match.prefix)) continue;
        var all_present = true;
        for (match.contains) |needle| {
            if (!containsIgnoreCase(line, needle)) {
                all_present = false;
                break;
            }
        }
        if (all_present) latest = position + indent;
    }
    return latest;
}

fn lastLinePrefixPosition(text: []const u8, prefixes: []const []const u8) ?usize {
    var position: usize = 0;
    var latest: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimStart(u8, line_raw, " \t\r");
        const indent = line_raw.len - line.len;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) latest = position + indent;
        }
        position += line_raw.len + 1;
    }
    return latest;
}

// ── 화면 region 슬라이싱 (순수·힙 없음) ────────────────────────────────────
// 화면 tail을 프롬프트 마커/수평선을 앵커로 구조 region으로 나눈다. 앵커 순서는 프롬프트 마커 우선 →
// 수평선 → whole tail 폴백이라, 박스를 그리지 않는 화면(스트리밍·평문 프롬프트)에서도 안전 바닥이 있다.

const ScreenSlice = struct { text: []const u8, offset: usize };

const max_scan_lines = 256;
const LineScan = struct {
    text: []const u8,
    starts: [max_scan_lines]usize = undefined,
    ends: [max_scan_lines]usize = undefined, // 개행 제외한 라인 끝
    count: usize = 0,
};

fn scanLines(text: []const u8) LineScan {
    var lines = LineScan{ .text = text };
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (lines.count >= max_scan_lines) break;
        lines.starts[lines.count] = offset;
        lines.ends[lines.count] = offset + line.len;
        lines.count += 1;
        offset += line.len + 1;
    }
    return lines;
}

const rule_codepoints = [_]u21{ 0x2500, 0x2501, 0x2550 }; // ─ ━ ═
const border_corner_codepoints = [_]u21{
    0x256D, 0x256E, 0x256F, 0x2570, // ╭ ╮ ╯ ╰
    0x250C, 0x2510, 0x2514, 0x2518, // ┌ ┐ └ ┘
    0x2554, 0x2557, 0x255A, 0x255D, // ╔ ╗ ╚ ╝
    0x251C, 0x2524, 0x252C, 0x2534, 0x253C, // ├ ┤ ┬ ┴ ┼
};

fn codepointIn(cp: u21, set: []const u21) bool {
    for (set) |c| if (c == cp) return true;
    return false;
}

/// 입력 박스 테두리/구분선 라인인지. 코너·정션을 허용해 둥근·이중 테두리도 인정하고, rule 문자만이거나
/// rule 문자가 3개 이상이면 수평선으로 본다.
fn isHorizontalRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    var view = std.unicode.Utf8View.init(trimmed) catch return false;
    var it = view.iterator();
    var rule_count: usize = 0;
    var other_count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (codepointIn(cp, &rule_codepoints)) {
            rule_count += 1;
        } else if (codepointIn(cp, &border_corner_codepoints)) {
            // 코너/정션은 테두리 구성요소이므로 other로 세지 않는다.
        } else other_count += 1;
    }
    if (rule_count == 0) return false;
    return other_count == 0 or rule_count >= 3;
}

/// 라인에서 앞의 박스 세로선 `│`와 공백을 벗긴 내용.
fn promptContent(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, t, "│")) t = std.mem.trimStart(u8, t["│".len..], " \t\r");
    return t;
}

fn isPromptLine(line: []const u8) bool {
    const content = promptContent(line);
    return std.mem.startsWith(u8, content, "❯") or std.mem.startsWith(u8, content, "›");
}

fn lineText(lines: *const LineScan, idx: usize) []const u8 {
    return lines.text[lines.starts[idx]..lines.ends[idx]];
}

/// 현재 입력 프롬프트 라인. 마지막 프롬프트라도 그 아래에 실제 출력이 남아 있으면 scrollback 잔상이므로
/// 현재 프롬프트가 아니다. "현재"의 구조적 정의는 두 갈래다.
///
/// - **박스 본문 갈래**: 프롬프트가 박스 상단 테두리 **바로 아래 첫 줄**이고 아래에도 닫는 수평선이 있으면, 그 사이는
///   사용자가 입력 중인 여러 행이다. 내용이 있어도 잔상 근거가 아니다 — 실측(claude)에서 입력 2행부터 이 검사가
///   프롬프트를 지워 idle 근거를 잃었다. "바로 아래 첫 줄"을 요구하는 이유는, 그렇지 않으면 위쪽 잔상 프롬프트와
///   아래 어딘가의 수평선(에이전트 출력에 흔한 구분선)만으로 잔상이 현재 프롬프트로 승격되기 때문이다.
/// - **공백 갈래**: 그 밖에는 프롬프트와 그 아래 첫 수평선 사이가 비어 있을 것(수평선이 없으면 화면 끝까지). 닫는
///   테두리가 없는 선택지 목록(`❯ 1. Yes` 아래에 다른 항목이 이어짐)과 출력이 이어지는 잔상 프롬프트가 여기서 걸러진다.
///   스캔을 **박스 안으로 한정**하는 것이 중요하다 — 화면 끝까지 훑으면 박스 아래 상태줄이 비-공백이라, 박스 안 두 번째
///   입력 행이 마커로 시작하는 경우(프롬프트 예시를 붙여넣기) 현재 프롬프트를 못 찾고 근거를 잃는다(코드 리뷰에서 재현).
///
/// 어느 갈래든 하단 거리(행 수)는 보지 않으므로 상태줄이 몇 줄이든, 입력이 몇 행이든 영향받지 않는다.
fn lastPromptLineIndex(lines: *const LineScan) ?usize {
    var i: usize = lines.count;
    while (i > 0) {
        i -= 1;
        if (!isPromptLine(lineText(lines, i))) continue;
        const limit = firstRuleBelow(lines, i) orelse lines.count;
        if (limit != lines.count) {
            if (nearestRuleAbove(lines, i)) |above| if (above + 1 == i) return i;
        }
        var j = i + 1;
        while (j < limit) : (j += 1) {
            if (std.mem.trim(u8, lineText(lines, j), " \t\r").len != 0) return null;
        }
        return i;
    }
    return null;
}

fn nearestRuleAbove(lines: *const LineScan, idx: usize) ?usize {
    var i: usize = idx;
    while (i > 0) {
        i -= 1;
        if (isHorizontalRule(lineText(lines, i))) return i;
    }
    return null;
}

fn firstRuleBelow(lines: *const LineScan, idx: usize) ?usize {
    var i: usize = idx + 1;
    while (i < lines.count) : (i += 1) {
        if (isHorizontalRule(lineText(lines, i))) return i;
    }
    return null;
}

fn lastRuleBelow(lines: *const LineScan, idx: usize) ?usize {
    var found: ?usize = null;
    var i: usize = idx + 1;
    while (i < lines.count) : (i += 1) {
        if (isHorizontalRule(lineText(lines, i))) found = i;
    }
    return found;
}

fn lastRuleOverall(lines: *const LineScan) ?usize {
    var found: ?usize = null;
    var i: usize = 0;
    while (i < lines.count) : (i += 1) {
        if (isHorizontalRule(lineText(lines, i))) found = i;
    }
    return found;
}

/// idx 라인 다음 라인의 시작 offset(마지막이면 text 끝).
fn lineStartAfter(lines: *const LineScan, idx: usize) usize {
    return if (idx + 1 < lines.count) lines.starts[idx + 1] else lines.text.len;
}

/// 미리 스캔한 라인 정보로 region 슬라이스를 얻는다(detect 당 1회 스캔 공유). 대상 텍스트는 `lines.text`가
/// 단일 출처다 — 별도 화면 인자를 받으면 스캔과 어긋난 버퍼가 넘어올 수 있어 받지 않는다.
fn regionSliceScanned(lines: *const LineScan, region: Region) ScreenSlice {
    const screen = lines.text;
    switch (region) {
        .screen => return .{ .text = screen, .offset = 0 },
        .title, .progress => return .{ .text = "", .offset = 0 },
        .prompt_anchor => {
            const p = lastPromptLineIndex(lines) orelse return .{ .text = "", .offset = 0 };
            return .{ .text = lineText(lines, p), .offset = lines.starts[p] };
        },
        .box_body => {
            const p = lastPromptLineIndex(lines) orelse return .{ .text = "", .offset = 0 };
            const above = nearestRuleAbove(lines, p);
            const below = firstRuleBelow(lines, p);
            const start = if (above) |a| lines.starts[a + 1] else lines.starts[p];
            const end = if (below) |b| lines.starts[b] else lines.ends[p];
            const s = @min(start, screen.len);
            const e = @min(@max(end, s), screen.len);
            return .{ .text = screen[s..e], .offset = s };
        },
        .output => {
            const p = lastPromptLineIndex(lines) orelse return .{ .text = screen, .offset = 0 };
            const above = nearestRuleAbove(lines, p);
            const end = if (above) |a| lines.starts[a] else lines.starts[p];
            const e = @min(end, screen.len);
            return .{ .text = screen[0..e], .offset = 0 };
        },
        .footer => {
            if (lastPromptLineIndex(lines)) |p| {
                const below = lastRuleBelow(lines, p);
                const start = if (below) |b| lineStartAfter(lines, b) else lineStartAfter(lines, p);
                const s = @min(start, screen.len);
                return .{ .text = screen[s..], .offset = s };
            }
            const last = lastRuleOverall(lines);
            const start = if (last) |b| lineStartAfter(lines, b) else 0;
            const s = @min(start, screen.len);
            return .{ .text = screen[s..], .offset = s };
        },
    }
}

/// 단발 편의 래퍼(테스트·외부 호출용). 프로덕션 detect 경로는 공유 스캔을 쓰는 regionSliceScanned를 쓴다.
fn regionSlice(screen: []const u8, region: Region) ScreenSlice {
    const lines = scanLines(screen);
    return regionSliceScanned(&lines, region);
}

pub const Stabilizer = struct {
    current: State = .unknown,
    last_evidence_ms: u64 = 0,
    evidence_missing: bool = false,
    /// 현재 상태가 화면·OSC 근거(`visible_*`)로 세워졌는지. 근거 없는 약한 신호(현재는 PTY activity 폴백 하나)가
    /// 근거 있는 상태를 즉시 덮지 못하게 하는 판단 재료다. 이게 없으면 타이핑 에코 같은 output이 근거 있는 idle을
    /// 곧바로 running으로 바꿔, 규칙 데이터를 고쳐도 같은 증상이 다른 화면에서 재발한다.
    evidence_backed: bool = false,

    pub const evidence_grace_ms: u64 = 700;

    pub fn reset(self: *Stabilizer) void {
        self.* = .{};
    }

    /// idle fast-path가 화면 재스캔을 생략해도 되는지 알려 준다. 한 번 no-match를 봤다면 grace 만료를
    /// 실제로 관측할 때까지 polling을 계속해야 stale idle이 영구 고착되지 않는다.
    pub fn needsExpiryProbe(self: Stabilizer) bool {
        return self.evidence_missing and self.current != .unknown;
    }

    /// 명시 신호는 즉시 반영한다. 일시적인 화면 재그리기에는 직전 상태를 짧게 유지하지만, 근거가 계속
    /// 사라진 상태를 running/blocked/idle로 무한 보존하지 않고 grace 뒤 unknown으로 실패시킨다.
    pub fn observe(self: *Stabilizer, detection: Detection, now_ms: u64) State {
        // skip 규칙: 매치했으나 상태 보류. 직전 상태가 있으면 근거만 갱신하고 상태는 유지한다.
        if (detection.skip) {
            if (self.current != .unknown) {
                self.last_evidence_ms = now_ms +| 1;
                self.evidence_missing = false;
            }
            return self.current;
        }
        if (detection.state != .unknown) {
            // 신호 세기 중재: 화면·OSC 근거가 없는 상태(약한 신호)는 근거 있는 직전 상태를 즉시 덮지 못한다.
            // 근거의 grace가 만료될 때까지 보류하고, 그 안에 같은 근거가 다시 오면 약한 신호는 버려진다.
            // 무기한 보류는 하지 않는다 — grace가 지나면 약한 신호가 이제 가장 최신 근거이므로 반영한다.
            if (!detection.hasVisibleEvidence() and self.evidence_backed and
                self.current != .unknown and self.current != detection.state)
            {
                self.evidence_missing = true;
                if (!self.graceExpired(now_ms)) return self.current;
            }
            self.current = detection.state;
            self.evidence_backed = detection.hasVisibleEvidence();
            self.last_evidence_ms = now_ms +| 1;
            self.evidence_missing = false;
            return self.current;
        }
        self.evidence_missing = true;
        if (self.current == .unknown) return .unknown;
        if (self.graceExpired(now_ms)) {
            self.current = .unknown;
            self.evidence_backed = false;
        }
        return self.current;
    }

    /// 직전 근거가 grace를 넘겼는지. `last_evidence_ms`는 "아직 근거 없음"을 0으로 구분하려고 +1 저장한다.
    fn graceExpired(self: Stabilizer, now_ms: u64) bool {
        if (self.last_evidence_ms == 0) return true;
        return now_ms -| (self.last_evidence_ms -| 1) >= evidence_grace_ms;
    }
};

test "claude manifest prioritizes a visible blocker over working text" {
    const d = detect(.claude, .{ .screen = "Working · esc to interrupt\nDo you want to proceed?\n❯ 1. Yes\nEsc to cancel" });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}

test "claude prompt and OSC progress report visible idle" {
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .screen = "────────────────\n❯ " }).state);
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .osc_progress = "4;0" }).state);
}

// [사용자 보고 2026-08-12] "클로드 동작 표시(파형)가 사라졌다 — 알림은 정상". 원인은 claude가 running OSC 타이틀의
// 스피너 계열을 **브라유에서 반원으로** 바꾼 것이다(2.1.228 실측 `◐`·`◑`). `working_title`이 브라유만 보고 있어
// running 근거가 통째로 사라지고, composer의 `❯`가 `live_prompt`(idle)로 이겨 **작업 중 세션이 "대기중"**이 됐다.
// 파형 문자열은 `.running`에서만 생성되므로 글리프 자체가 안 그려졌다(색 문제가 아니었다).
//
// 이 판정자는 **두 계열을 함께** 고정한다 — 한쪽만 두면 같은 사고가 반대 방향으로 재발한다(구버전 롤백·다른 provider).
// composer가 열린 화면을 함께 주는 것이 요점이다: 그 조합이 실제 화면이고, running 근거가 없으면 idle이 이긴다.
test "claude running title accepts both braille and half-circle spinner families (2.1.218 · 2.1.228 실측)" {
    const composer_open = "────────────────\n❯ ";
    // 2.1.228 실측 프레임 — 이것이 idle로 판정되던 회귀.
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "◐ 탐색기 에러 모달 텍스트 확인", .screen = composer_open }).state);
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "◑ 무언가 하는 중", .screen = composer_open }).state);
    // 2.1.218 실측 프레임 — 넓히면서 잃지 않았음을 함께 고정한다.
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "\u{2810} 무언가 하는 중", .screen = composer_open }).state);
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "\u{2802} 무언가 하는 중", .screen = composer_open }).state);
    // idle 마커(`✳`)는 그대로 idle이어야 한다 — 넓힌 범위가 idle 타이틀을 삼키면 "항상 running"이 된다.
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .osc_title = "\u{2733} 대기 중 요약", .screen = composer_open }).state);
}

test "codex working title and action-required title are distinct" {
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_title = "⠋ Working" }).state);
    try std.testing.expectEqual(State.blocked, detect(.codex, .{ .osc_title = "Action Required" }).state);
}

test "codex startup selection screens are blocked until the user confirms" {
    const update = detect(.codex, .{ .screen = "1. Update now\n2. Skip\nPress enter to continue" });
    try std.testing.expectEqual(State.blocked, update.state);
    try std.testing.expect(update.visible_blocker);

    const hooks = detect(.codex, .{ .screen = "Hooks need review\n3. Continue without trusting\nPress enter to confirm or esc to go back" });
    try std.testing.expectEqual(State.blocked, hooks.state);
    try std.testing.expect(hooks.visible_blocker);
}

test "codex interruption screen becomes idle even after output activity" {
    const d = detect(.codex, .{ .screen = "■ Conversation interrupted\n› ", .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "current running footer beats a prior prompt or interruption in the screen tail" {
    try std.testing.expectEqual(State.running, detect(.claude, .{ .screen = "❯ previous prompt\nWorking… esc to interrupt" }).state);
    // codex footer는 실측 문구(닫는 괄호 포함)로 적는다 — 산문 오탐을 막으려고 규칙이 괄호까지 요구한다.
    try std.testing.expectEqual(State.running, detect(.codex, .{ .screen = "■ Conversation interrupted\n› previous prompt\n• Working (2s • Esc to interrupt)" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .screen = "■ Conversation interrupted", .osc_progress = "4;2", .osc_title = "✳" }).state);
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_progress = "4;2", .osc_title = "✳" }).state);
}

test "codex steering composer below a working footer remains running" {
    // footer 줄은 실측 모양(`• Working (…)`)으로 적는다. 규칙이 **한 줄 안에서** 불릿 + `working` + `esc to interrupt`를
    // 요구하므로, 불릿 없는 합성 문구는 더 이상 footer로 인정되지 않는다(산문 인용 오탐을 막는 대가).
    const d = detect(.codex, .{ .screen = "• Working (8s · esc to interrupt)\n› Add a follow-up" });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

test "current prompt below a stale running footer becomes idle" {
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .screen = "Working… esc to interrupt\nanswer\n❯ " }).state);
    // Codex는 현재 `esc to interrupt`가 있으면 아래 prompt도 steering composer라 running이다. footer가 사라지고 과거
    // Working 텍스트만 남은 뒤 새 prompt가 보일 때 idle로 복귀한다.
    try std.testing.expectEqual(State.idle, detect(.codex, .{ .screen = "Working\nanswer\n› " }).state);
}

test "prompt outside the bounded bottom region is not current idle evidence" {
    try std.testing.expectEqual(State.unknown, detect(.claude, .{ .screen = "❯ old\n1\n2\n3\n4\n5" }).state);
}

test "activity is a running fallback and silence is unknown" {
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_progress = "4;1;50" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_progress = "4;3" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .output_active = true }).state);
    try std.testing.expectEqual(State.unknown, detect(.codex, .{}).state);
}

test "stabilizer publishes evidence immediately and expires stale state to unknown" {
    var s: Stabilizer = .{ .current = .running };
    const explicit_idle: Detection = .{ .state = .idle, .rule_id = "prompt", .visible_idle = true };
    try std.testing.expectEqual(State.idle, s.observe(explicit_idle, 10));
    try std.testing.expectEqual(State.idle, s.observe(.{ .state = .unknown, .rule_id = "no_match" }, 709));
    try std.testing.expect(s.needsExpiryProbe());
    try std.testing.expectEqual(State.unknown, s.observe(.{ .state = .unknown, .rule_id = "no_match" }, 710));
    try std.testing.expect(!s.needsExpiryProbe());
}

// ── region·게이트 엔진 (규칙 이관 전 격리 검증) ──────────────────────────────

test "isHorizontalRule는 둥근·이중·순수 테두리를 인정하고 일반 텍스트는 거부한다" {
    try std.testing.expect(isHorizontalRule("╭───╮"));
    try std.testing.expect(isHorizontalRule("╔═══╗"));
    try std.testing.expect(isHorizontalRule("────"));
    try std.testing.expect(isHorizontalRule("━━━━"));
    try std.testing.expect(!isHorizontalRule("normal text line"));
    try std.testing.expect(!isHorizontalRule(""));
}

test "region output/footer/box_body가 다중 수평선 박스에서 prompt를 정확히 가른다" {
    const screen =
        "● output line\n" ++
        "╭─────╮\n" ++
        "│ ❯ hi │\n" ++
        "╰─────╯\n" ++
        "───────\n" ++
        "  Esc to interrupt\n";
    try std.testing.expect(containsIgnoreCase(regionSlice(screen, .footer).text, "esc to interrupt"));
    const output = regionSlice(screen, .output).text;
    try std.testing.expect(containsIgnoreCase(output, "output line"));
    try std.testing.expect(!containsIgnoreCase(output, "❯ hi"));
    const body = regionSlice(screen, .box_body).text;
    try std.testing.expect(containsIgnoreCase(body, "❯ hi"));
    try std.testing.expect(!containsIgnoreCase(body, "esc to interrupt"));
    try std.testing.expect(containsIgnoreCase(regionSlice(screen, .prompt_anchor).text, "❯ hi"));
}

test "region은 박스 없는 화면에서 마커/whole tail로 폴백한다" {
    const streaming = "● Reading files…\n  Searching\nWorking… esc to interrupt\n";
    try std.testing.expect(regionSlice(streaming, .prompt_anchor).text.len == 0);
    try std.testing.expect(containsIgnoreCase(regionSlice(streaming, .footer).text, "esc to interrupt"));

    const plain = "● Done.\n❯ \n";
    try std.testing.expect(!containsIgnoreCase(regionSlice(plain, .footer).text, "esc"));
    const out = regionSlice(plain, .output).text;
    try std.testing.expect(containsIgnoreCase(out, "Done"));
    try std.testing.expect(!containsIgnoreCase(out, "❯"));
}

test "footer region 규칙은 과거 output의 esc는 무시하고 현재 footer만 running으로 본다" {
    const rules = [_]Rule{
        .{ .id = "footer_running", .state = .running, .priority = 100, .region = .footer, .any = &.{"esc to interrupt"}, .visible_running = true },
    };
    // 과거 esc가 박스 위 output에만 있으면 footer는 비어 매치하지 않는다.
    const stale = "Working esc to interrupt\nanswer\n╭───╮\n│ ❯ │\n╰───╯\n";
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = stale }).state);
    // 박스 아래 footer에 esc가 있으면 running.
    const running = "● out\n╭───╮\n│ ❯ │\n╰───╯\n  esc to interrupt\n";
    try std.testing.expectEqual(State.running, detectWithRules(&rules, .{ .screen = running }).state);
}

test "중첩 all/any/not 게이트가 detectWithRules에서 평가된다" {
    const rules = [_]Rule{
        .{ .id = "gated_blocker", .state = .blocked, .priority = 100, .region = .screen, .visible_blocker = true, .gate = .{
            .all = &.{.{ .contains = &.{"do you want to proceed?"} }},
            .any = &.{ .{ .contains = &.{"esc to cancel"} }, .{ .contains = &.{"tab to amend"} } },
            .not = &.{.{ .contains = &.{"conversation interrupted"} }},
        } },
    };
    try std.testing.expectEqual(State.blocked, detectWithRules(&rules, .{ .screen = "Do you want to proceed?\n❯ 1. Yes\nEsc to cancel" }).state);
    // any 미충족
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = "Do you want to proceed?\n(no options)" }).state);
    // not 위배
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = "Do you want to proceed? esc to cancel\nConversation interrupted" }).state);
}

test "skip_state_update 규칙은 매치해도 상태를 바꾸지 않고 직전 상태를 유지한다" {
    const rules = [_]Rule{
        .{ .id = "loading", .state = .unknown, .priority = 100, .region = .screen, .all = &.{"reticulating splines"}, .skip_state_update = true },
    };
    const d = detectWithRules(&rules, .{ .screen = "reticulating splines" });
    try std.testing.expect(d.skip);
    var s: Stabilizer = .{ .current = .running };
    try std.testing.expectEqual(State.running, s.observe(d, 10)); // 보류: running 유지
    try std.testing.expectEqual(State.running, s.observe(d, 20));
}

// ── 게이트 경화 회귀 ────────────────────────────────────────────────────────

test "양성 매처 없는 게이트는 매치로 치지 않는다" {
    // 빈 게이트가 참이면 규칙이 모든 화면에서 조용히 발화한다. 빌드 검증(validateGate)이 1차 방어이고,
    // 런타임에서도 매치로 치지 않는지 여기서 못박는다.
    try std.testing.expect(gateMatchSpan(.{}, "아무 화면") == null);
    try std.testing.expect(gateMatchSpan(.{}, "") == null);
    try std.testing.expect(gateMatchSpan(.{ .any = &.{.{}} }, "무엇이든") == null);
    try std.testing.expect(!gateHasPositiveMatcher(.{}));
    try std.testing.expect(gateHasPositiveMatcher(.{ .contains = &.{"x"} }));
}

test "게이트 매치 위치는 region 끝이 아니라 근거가 보이는 자리다" {
    const screen = "esc to interrupt\nanswer\nready";
    // 가장 위 줄의 근거를 잡으면 위치도 그 자리여야 한다(region 끝이면 screen.len이 되어 항상 최댓값).
    const pos = gateMatchSpan(.{ .contains = &.{"esc to interrupt"} }, screen).?.latest;
    try std.testing.expectEqual(@as(usize, 0), pos);
    try std.testing.expect(pos < screen.len);
    // 여러 근거면 더 아래(최신) 자리를 쓴다.
    const lower = gateMatchSpan(.{ .contains = &.{ "esc to interrupt", "ready" } }, screen).?.latest;
    try std.testing.expectEqual(std.mem.indexOf(u8, screen, "ready").?, lower);
}

test "게이트 규칙이 위치 tiebreak에서 아래쪽 화면 규칙에 지고 이긴다" {
    // 게이트 근거가 위, 평면 근거가 아래 → 아래(평면)가 이긴다.
    const rules = [_]Rule{
        .{ .id = "gated_top", .state = .running, .priority = 100, .region = .screen, .gate = .{ .contains = &.{"esc to interrupt"} }, .visible_running = true },
        .{ .id = "flat_bottom", .state = .idle, .priority = 100, .region = .screen, .any = &.{"ready now"}, .visible_idle = true },
    };
    try std.testing.expectEqual(State.idle, detectWithRules(&rules, .{ .screen = "esc to interrupt\nanswer\nready now" }).state);
    // 반대로 게이트 근거가 아래면 게이트가 이긴다.
    try std.testing.expectEqual(State.running, detectWithRules(&rules, .{ .screen = "ready now\nanswer\nesc to interrupt" }).state);
}

// ── 실 화면 캡처 기반 fixture (claude 2.1.218, tmux 140×45) ──────────────────
// 캡처로 확인한 사실: OSC 타이틀이 주 신호(작업=브라유 스피너, 대기=✳), 입력 줄은 수평선 사이 bare `❯`,
// 그 아래 사용자 statusLine이 여러 줄, 작업 중에도 composer가 열려 있고 `esc to interrupt` 문구는 없다.

test "claude 실측: 브라유 스피너 타이틀은 프레임이 달라도 running으로 잡힌다" {
    // 실제 관측 프레임 U+2810 / U+2802 — 과거 열거하던 10프레임에는 없던 값이다.
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "⠐ 터미널에 대한 haiku 작성" }).state);
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "⠂ 터미널에 대한 haiku 작성" }).state);
    // 과거 프레임도 같은 블록이라 그대로 커버(회귀 없음).
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "⠋ Working" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_title = "⠐ Working" }).state);
}

test "claude 실측: 대기 타이틀 ✳는 idle이고 스피너 범위에 걸리지 않는다" {
    const d = detect(.claude, .{ .osc_title = "✳ 터미널에 대한 haiku 작성" });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 커스텀 statusLine이 여러 줄이어도 입력 줄을 idle로 잡는다" {
    // 하단 거리 가드였다면 상태줄 4줄에 밀려 잔상으로 오인됐을 화면.
    const screen =
        "● Done. Updated 3 files.\n" ++
        "────────────────────────\n" ++
        "❯ \n" ++
        "────────────────────────\n" ++
        "  yoonhb\n" ++
        "  ctx 3% │ 5h 8% (00:20) │ 7d 49% (07/28 12:00)\n" ++
        "  Opus 4.8 (1M context) │ █ xhigh\n" ++
        "  ⏸ manual mode on · ← 1 agent";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 작업 중에는 composer가 열려 있어도 스피너 타이틀이 idle을 이긴다" {
    const screen =
        "✳ Flibbertigibbeting… (2s · thinking with xhigh effort)\n" ++
        "────────────────────────\n" ++
        "❯ \n" ++
        "────────────────────────\n" ++
        "  yoonhb\n" ++
        "  Opus 4.8 (1M context) │ █ xhigh";
    const d = detect(.claude, .{ .screen = screen, .osc_title = "⠂ 터미널에 대한 haiku 작성" });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

// ── 실 화면 캡처 기반 fixture (codex 0.146.0, tmux 80×24) ────────────────────
// 사용자 입력이 여러 행이 되면 상시 chrome(composer·실행 footer)이 스스로 위로 밀린다. 캡처로 확인한 배치:
// idle은 `› 입력` + 빈 행 + `Context …` 상태줄(상수 2행), 실행 중은 `› 에코` → `• Working (… esc to interrupt)`
// → `› steering 입력` → `tab to queue message …` 순으로 **실행 footer가 live composer보다 위**에 온다.
// 수평선 폭만 가독성을 위해 줄였고 마커·문구·행 구성은 캡처 그대로다(docs/agent-session.md «실측 신호 기록»).

test "codex 실측: composer 입력이 여러 행이어도 타이핑이 running으로 보이지 않는다" {
    // 입력 4행이면 `›` 마커의 하단 거리가 5가 되어, 거리 게이트가 있던 시절엔 유일한 idle 근거가 사라졌다.
    // 그러면 PTY activity 폴백만 남아 **타이핑 에코가 running으로 단정**된다(사용자 보고 증상).
    const screen =
        "  Tip: Try the Desktop app. Run 'codex app' or visit\n" ++
        "  https://chatgpt.com/codex?app-landing-page=true\n" ++
        "\n" ++
        "\n" ++
        "› please refactor the observer module so that the distance guard no longer\n" ++
        "  decides whether the composer is current, and add fixtures and also please\n" ++
        "  double check the stabilizer arbitration path because weak signals must not\n" ++
        "  override evidence backed states in any case\n" ++
        "\n" ++
        "  Context 0% used · weekly 67% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
    try std.testing.expect(!std.mem.eql(u8, d.rule_id, "pty_activity"));
}

test "codex 실측: 입력이 12행을 넘는 composer도 tail에 들어오면 idle이다" {
    // 실측(0.146.0): composer는 입력 행 수만큼 제한 없이 자란다(개행 18행까지 확인). 규칙 쪽은 행 수에 무관하지만,
    // platform이 넘기는 tail 행 상한이 짧으면 마커 자체가 tail 밖으로 나가 근거가 사라진다. 그 상한이 이 화면을
    // 계속 실어 주는지가 회귀 지점이라, 규칙이 이 모양에서 idle을 내는 것을 여기서 못박는다.
    const screen =
        "› line1\n  line2\n  line3\n  line4\n  line5\n  line6\n  line7\n" ++
        "  line8\n  line9\n  line10\n  line11\n  line12\n  line13\n  line14\n" ++
        "\n" ++
        "  Context 4% used · weekly 67% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "codex 실측: 실행 중 steering 배치는 output이 조용해도 running이다" {
    // footer의 하단 거리가 6이라, 거리 게이트가 있으면 **실제 작업 중에도** running 근거가 사라진다(반대 방향 결함).
    // output_active=false로 두어 폴백이 아니라 화면 근거로 running이 나오는지 못박는다.
    const screen =
        "  20\n" ++
        "\n" ++
        "› write a detailed 12 line haiku sequence about terminals, thinking carefully\n" ++
        "  about each line\n" ++
        "\n" ++
        "\n" ++
        "• Working (3s • esc to interrupt)\n" ++
        "\n" ++
        "\n" ++
        "› also please make sure the last line rhymes with the first line and keep the\n" ++
        "  whole thing under twenty words total in the end\n" ++
        "\n" ++
        "  tab to queue message                                        96% context left\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = false });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

test "codex 실측: turn이 끝나 footer가 사라진 화면은 idle이다" {
    // `• Working …` 행은 turn 종료 시 화면에서 사라진다(스크롤로 남지 않는다) → `esc to interrupt` 부재가 완료 근거다.
    const screen =
        "  19\n" ++
        "\n" ++
        "  20\n" ++
        "\n" ++
        "\n" ++
        "› Implement {feature}\n" ++
        "\n" ++
        "  Context 4% used · weekly 67% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "codex: 산문에 언급된 esc to interrupt는 running 근거가 아니다" {
    // 적대적 검증에서 나온 케이스. footer 문구를 괄호 없이 느슨하게 잡으면, 에이전트가 그 표현을 설명하기만 해도
    // idle 근거가 지워지고 거짓 running이 선다. 터미널을 만드는 저장소에서는 이 산문이 실제로 나온다.
    const screen =
        "● 규칙은 화면에 `esc to interrupt` 문구가 보이는지로 판정합니다.\n" ++
        "  그 문구가 사라지면 turn이 끝난 것으로 봅니다.\n" ++
        "\n" ++
        "› \n" ++
        "\n" ++
        "  Context 7% used · weekly 61% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 입력이 여러 행이어도 입력 줄이 idle 근거다" {
    // claude 박스는 여러 행 입력을 상·하단 수평선 사이에 담는다. 그 본문은 사용자 입력이므로 프롬프트가 잔상이라는
    // 근거가 아니다. 여기서는 OSC 타이틀을 비워, ✳ 타이틀에 가려지지 않고 화면만으로 판정되는지 확인한다.
    const screen =
        "\n" ++
        "  tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf\n" ++
        "────────────────────────────────────\n" ++
        "❯ please refactor the observer module so that the distance guard no longer\n" ++
        "  decides whether the composer is current, and add fixtures grounded in real\n" ++
        "  captures\n" ++
        "────────────────────────────────────\n" ++
        "  codexprobe\n" ++
        "  Opus 5 (1M context) │ █ xhigh\n" ++
        "  ⏸ manual mode on\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 박스 밖 선택지 목록은 여러 행이어도 입력 프롬프트가 아니다" {
    // 박스 본문 허용이 선택지 목록까지 열어 주면 안 된다. 신뢰 확인 화면은 마커 아래에 수평선이 없으므로
    // “아래가 모두 공백” 판정이 그대로 적용돼 프롬프트로 승격되지 않는다(blocker 문구를 뺀 최소 화면으로 확인).
    const screen =
        " Quick safety check: Is this a project you created or one you trust?\n" ++
        "\n" ++
        " ❯ 1. Yes, I trust this folder\n" ++
        "   2. No, exit\n";
    try std.testing.expectEqual(State.unknown, detect(.claude, .{ .screen = screen }).state);
}

test "claude: 출력 구분선만 아래에 있는 잔상 프롬프트는 현재 프롬프트가 아니다" {
    // 적대적 검증에서 나온 케이스. 박스 본문 허용을 "아래에 수평선이 있으면"으로 두면, 에이전트 출력에 흔한 구분선
    // 하나만으로 위쪽 잔상 프롬프트가 현재 프롬프트로 승격된다. 그래서 프롬프트가 박스 상단 바로 아래 첫 줄일 것을
    // 함께 요구한다(composer는 항상 그 형태다).
    const screen =
        "❯ 예전 프롬프트\n" ++
        "● Reading files…\n" ++
        "────────────────\n" ++
        "  더 많은 출력\n";
    try std.testing.expectEqual(State.unknown, detect(.claude, .{ .screen = screen }).state);
}

test "실행 footer 규칙은 아래 상태줄이 길어도 무효화되지 않는다" {
    // 상시 chrome 규칙에는 하단 거리 게이트를 걸지 않는다. 사용자 statusLine이 4행이면 거리 게이트가 실행 근거까지
    // 지워 버린다(그 화면에는 idle 근거도 없어 결과가 unknown이 된다).
    const screen =
        "────────────────────────────────────\n" ++
        "❯ steering input row one\n" ++
        "  steering input row two\n" ++
        "────────────────────────────────────\n" ++
        "  esc to interrupt\n" ++
        "  yoonhb\n" ++
        "  ctx 3% │ 5h 8% (00:20)\n" ++
        "  Opus 5 (1M context) │ █ xhigh\n" ++
        "  ⏸ manual mode on\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

// ── 코드 리뷰 재현 회귀 (max 리뷰에서 실제로 오판이 재현된 화면) ──────────────

test "claude: composer 본문에 든 esc to interrupt는 실행 근거가 아니다" {
    // live_prompt의 위치는 프롬프트 **라인 시작** offset이라, 본문에 있는 문구는 항상 그보다 아래(큰 offset)다.
    // working_footer가 `screen`이던 동안에는 위치 tiebreak가 무조건 footer 손을 들어, 이 기능을 물어보는 문장을
    // 타이핑하는 것만으로 스피너가 돌았다. region을 footer로 좁혀 입력 본문(box_body)과 실행 chrome을 구조로 가른다.
    const screen =
        "────────────────────\n" ++
        "❯ esc to interrupt 는 어떻게 판정되나요\n" ++
        "  두 번째 입력 행\n" ++
        "────────────────────\n" ++
        "  yoonhb\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude: 박스 안 두 번째 입력 행이 마커로 시작해도 현재 프롬프트를 찾는다" {
    // 공백 갈래 스캔이 박스를 넘어 화면 끝까지 가면, 아래 상태줄이 비-공백이라 근거를 통째로 잃는다.
    const screen =
        "────────────────────\n" ++
        "❯ 예시를 보여줘\n" ++
        "❯ 이런 프롬프트 말이야\n" ++
        "────────────────────\n" ++
        "  yoonhb\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude: 멀리 떨어진 조건 조각이 조합돼 blocked를 만들지 않는다" {
    // 거리 게이트를 **가장 아래 근거**로만 재던 동안에는, 위쪽 산문의 질문과 아래 composer에 사용자가 친 `yes`가
    // 조합돼 거짓 blocked가 섰다. blocked는 절대 우선이라 카드가 입력 대기로 표시되고 워크스페이스 대표까지 됐다.
    const screen =
        "Do you want to proceed?\no1\no2\no3\no4\no5\no6\no7\no8\n" ++
        "────────────────────\n" ++
        "❯ yes 좋아요\n" ++
        "────────────────────\n" ++
        "  yoonhb\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(!d.visible_blocker);
}

test "claude 실측: 권한 다이얼로그는 옵션이 늘어도 blocked다" {
    // 실측(2.1.x, 100×30): 다이얼로그가 composer·statusLine을 **대체**하고 마지막 줄이 힌트다. 질문은 옵션 3개일 때
    // 하단에서 5행이고 옵션마다 1행씩 밀린다 — 거리 상한이 6이면 옵션 4개부터 놓친다.
    const real =
        "⏺ Running 1 shell command…\n" ++
        "  ⎿  $ date +%s > stamp.txt\n" ++
        "\n" ++
        "──────────────────────────────\n" ++
        " Bash command\n" ++
        "\n" ++
        "   date +%s > stamp.txt\n" ++
        "   Write current epoch timestamp to stamp.txt\n" ++
        "\n" ++
        " Do you want to proceed?\n" ++
        " ❯ 1. Yes\n" ++
        "   2. Yes, and always allow access to codexprobe/ from this project\n" ++
        "   3. No\n" ++
        "\n" ++
        " Esc to cancel · Tab to amend · ctrl+e to explain";
    const d = detect(.claude, .{ .screen = real });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);

    const five_options =
        " Do you want to proceed?\n ❯ 1. Yes\n   2. B\n   3. C\n   4. D\n   5. No\n\n Esc to cancel · Tab to amend";
    try std.testing.expectEqual(State.blocked, detect(.claude, .{ .screen = five_options }).state);
}

test "codex 실측: footer 뒤에 다른 항목이 붙어도 running이다" {
    // 문구를 `esc to interrupt)`처럼 괄호까지 붙여 요구하면, footer 뒤에 항목이 하나 붙거나 wrap으로 `)`가 다음 줄로
    // 밀리는 순간 running 근거가 사라진다. 그때 아래 composer가 **근거 있는 idle**을 세워, 작업 중인 세션이 turn 내내
    // "대기중"으로 보인다(코드 리뷰에서 재현 — 거짓 running을 피하려다 더 나쁜 거짓 idle을 만든 셈이었다).
    const screen = "› echo\n• Working (3s • esc to interrupt • ctrl+t for details)\n› steer\n  tab to queue message\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = false });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

test "codex: 승인이 끝난 오래된 allow command?는 idle 근거를 지우지 않는다" {
    // `none`에 두면 tail이 넓어질 때 이미 승인된 문구가 유일한 idle 근거를 지우고, confirmation_prompt는 거리 게이트
    // 밖이라 blocked도 못 나와 폴백이 타이핑을 running으로 만든다. 승인 화면 자체는 blocker 우선 규칙이 이미 이긴다.
    const screen = "Allow command?\nout1\nout2\nout3\nout4\nout5\nout6\nout7\n› \n\n  Context 4% used\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
    // 현재 승인 화면은 그대로 blocked여야 한다(중복이라 뺀 것이지 약화가 아니다).
    try std.testing.expectEqual(State.blocked, detect(.codex, .{ .screen = "Allow command?\n› 1. Yes\n" }).state);
}

test "codex: 산문에 인용된 footer 리터럴은 running 근거가 아니다" {
    // 같은 줄에 `working`과 `esc to interrupt`가 함께 있어도, 실행 footer는 불릿으로 시작하는 한 줄이라는 모양까지
    // 요구하므로 문장 안 인용은 걸러진다. 리뷰가 지적한 대로 이 저장소 문서·fixture에 그 리터럴이 실제로 들어 있다.
    const screen =
        "● `• Working (3s • esc to interrupt)` 문구 한 줄로 판정합니다\n" ++
        "\n" ++
        "› \n" ++
        "\n" ++
        "  Context 7% used · weekly 61% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "같은 줄 게이트는 서로 다른 줄의 조각을 조합하지 않는다" {
    try std.testing.expect(lastLineMatchPosition("working\nesc to interrupt", .{ .contains = &.{ "working", "esc to interrupt" } }) == null);
    try std.testing.expect(lastLineMatchPosition("• Working (3s • esc to interrupt)", .{ .prefix = "•", .contains = &.{ "working", "esc to interrupt" } }) != null);
    // 불릿이 없으면 매치하지 않는다(문장 안 인용 방어).
    try std.testing.expect(lastLineMatchPosition("● 인용: Working esc to interrupt", .{ .prefix = "•", .contains = &.{ "working", "esc to interrupt" } }) == null);
    // 여러 줄이 맞으면 가장 아래(최신) 위치를 쓴다.
    const two = "• Working (1s • esc to interrupt)\n• Working (2s • esc to interrupt)";
    try std.testing.expectEqual(std.mem.lastIndexOf(u8, two, "• Working").?, lastLineMatchPosition(two, .{ .prefix = "•", .contains = &.{"esc to interrupt"} }).?);
}

// ── 신호 세기 중재 ──────────────────────────────────────────────────────────

test "약한 신호는 근거 있는 상태를 즉시 덮지 못하고 grace 만료 뒤에만 반영된다" {
    var s: Stabilizer = .{};
    const strong_idle: Detection = .{ .state = .idle, .rule_id = "live_prompt", .visible_idle = true };
    const weak_running: Detection = .{ .state = .running, .rule_id = "pty_activity" };
    try std.testing.expectEqual(State.idle, s.observe(strong_idle, 1_000));
    // 타이핑 에코도 output이므로 폴백은 running을 말한다. 화면 근거가 없는 그 말이 idle을 덮으면 안 된다.
    try std.testing.expectEqual(State.idle, s.observe(weak_running, 1_100));
    try std.testing.expectEqual(State.idle, s.observe(weak_running, 1_600));
    try std.testing.expect(s.needsExpiryProbe());
    // 같은 근거가 다시 오면 grace가 갱신되어 계속 idle이다.
    try std.testing.expectEqual(State.idle, s.observe(strong_idle, 1_650));
    try std.testing.expectEqual(State.idle, s.observe(weak_running, 2_300));
    // 근거가 grace 안에 재확인되지 않으면 그때 약한 신호가 최신 근거가 된다(무기한 보류 금지).
    try std.testing.expectEqual(State.running, s.observe(weak_running, 2_351));
    try std.testing.expect(!s.needsExpiryProbe());
}

test "근거 있는 상태가 없거나 같은 상태면 약한 신호를 그대로 반영한다" {
    var s: Stabilizer = .{};
    const weak_running: Detection = .{ .state = .running, .rule_id = "pty_activity" };
    try std.testing.expectEqual(State.running, s.observe(weak_running, 10));
    try std.testing.expectEqual(State.running, s.observe(weak_running, 110));
    // 강한 근거는 언제나 즉시 이긴다.
    try std.testing.expectEqual(State.idle, s.observe(.{ .state = .idle, .rule_id = "live_prompt", .visible_idle = true }, 120));
}

test "claude 실측: 폴더 신뢰 확인 화면은 blocked이고 선택지를 입력 프롬프트로 오인하지 않는다" {
    const screen =
        "Quick safety check: Is this a project you created or one you trust?\n" ++
        "❯ 1. Yes, I trust this folder\n" ++
        "  2. No, exit\n" ++
        "\n" ++
        "Enter to confirm · Esc to cancel";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}

// 아래 세 테스트는 **플랜 승인·도구 권한 대기가 유휴로 보이던 회귀**를 막는다. 화면 텍스트는 tmux 120칸/72칸 pane에서
// 실제 claude 2.1.226을 plan mode로 돌려 캡처한 것을 발췌했다(추측 문구가 아니다). 터미널에서 중요한 이유: blocked는
// 절대 우선이라 이 판정이 틀리면 사이드바 카드와 워크스페이스 대표 상태가 "입력을 기다리는 중"을 유휴로 표시하고,
// 관측 주도 attention 알림(docs/agent-session.md)이 발화할 근거 자체가 사라진다.

test "claude 실측: 플랜 승인 대기는 blocked다(Would you like to proceed? — proceed 규칙과 다른 문구)" {
    // 실측 발췌: 승인 UI가 composer를 대체해 프롬프트 줄이 없고, esc/enter 힌트도 없다.
    const screen =
        "   - 내용: Hello, world! 한 줄\n" ++
        "  ────────────────────────────────────────\n" ++
        "   Claude has written up a plan and is ready to execute. Would you like to proceed?\n" ++
        "\n" ++
        "   ❯ 1. Yes, and use auto mode\n" ++
        "     2. Yes, manually approve edits\n" ++
        "     3. Tell Claude what to change\n" ++
        "        shift+tab to approve with this feedback\n" ++
        "\n" ++
        "   ctrl+g to edit in Vim · ~/.claude/plans/hello-txt-calm-nebula.md";
    // OSC 타이틀의 `✳`는 idle 근거(`idle_title`)다. blocker가 절대 우선이므로 승인 대기가 유휴로 뒤집히면 안 된다.
    const d = detect(.claude, .{ .screen = screen, .osc_title = "✳ Create hello.txt file planning" });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);

    // 좁은 창(실측 72칸): 안내 문장이 `… Would you` / `like to proceed?`로 끊겨도 짧은 앵커가 살아남아야 한다.
    const narrow =
        "  ────────────────────────────────────────────────────────────────────\n" ++
        "   Claude has written up a plan and is ready to execute. Would you\n" ++
        "   like to proceed?\n" ++
        "\n" ++
        "   ❯ 1. Yes, and use auto mode\n" ++
        "     2. Yes, manually approve edits\n" ++
        "     3. Tell Claude what to change\n" ++
        "        shift+tab to approve with this feedback\n" ++
        "\n" ++
        "   ctrl+g to edit in Vim ·\n" ++
        "   ~/.claude/plans/hello-txt-memoized-origami.md";
    try std.testing.expectEqual(State.blocked, detect(.claude, .{ .screen = narrow, .osc_title = "✳ 계획" }).state);
}

test "claude 실측: 권한 다이얼로그는 질문 문구가 도구마다 달라도 blocked다" {
    // 실측: Write 도구는 `Do you want to create hello.txt?`를 쓴다 — `proceed?`가 아니라 permission_prompt가 미스했다.
    const screen =
        "⏺ Write(hello.txt)\n" ++
        " ────────────────────────────────────────\n" ++
        " Create file\n" ++
        " hello.txt\n" ++
        " Do you want to create hello.txt?\n" ++
        " ❯ 1. Yes\n" ++
        "   2. Yes, allow all edits during this session (shift+tab)\n" ++
        "   3. No\n" ++
        "\n" ++
        " Esc to cancel · Tab to amend";
    const d = detect(.claude, .{ .screen = screen, .osc_title = "✳ Claude Code" });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}

test "claude: 승인 문구가 대화 본문·composer에 있으면 blocked가 아니다(footer region 경계)" {
    // 실제 TUI는 composer를 늘 수평선 사이에 두므로, footer는 상태줄만 된다 → 같은 문구가 있어도 region 밖이다.
    // `.screen` 기반 규칙이었을 때 이 세 화면이 전부 거짓 blocked였다(재현 후 이 테스트로 고정).
    const typed_anchor =
        "⏺ 알겠습니다.\n" ++
        "────────────────────────\n" ++
        " ❯ Would you like to proceed? 문구를 찾아 1. yes 옵션을 추가해줘\n" ++
        "────────────────────────\n" ++
        "  maru │ main";
    const spoken_anchor =
        "⏺ 플랜 UI는 written up a plan and is ready 문구를 씁니다.\n" ++
        "────────────────────────\n" ++
        " ❯ \n" ++
        "────────────────────────\n" ++
        "  maru │ main";
    const typed_footer_hint =
        "⏺ 승인 화면에는 esc to cancel 과 tab to amend 가 뜹니다.\n" ++
        "────────────────────────\n" ++
        " ❯ \n" ++
        "────────────────────────\n" ++
        "  maru │ main";
    try std.testing.expect(detect(.claude, .{ .screen = typed_anchor }).state != .blocked);
    try std.testing.expect(detect(.claude, .{ .screen = spoken_anchor }).state != .blocked);
    try std.testing.expect(detect(.claude, .{ .screen = typed_footer_hint }).state != .blocked);
}

// codex 승인 화면은 composer를 대체하므로 `›` 입력 줄이 없다. 그 비대칭이 "지금 승인을 기다리는 화면"과 "사용자가
// 승인 문구를 타이핑 중인 화면"을 가르는 유일한 관측 근거다. 터미널에서 중요한 이유: blocked는 절대 우선이라
// 거짓 blocked는 작업 중인 세션을 입력 대기로 뒤집고 워크스페이스 대표 상태까지 오염시킨다.

test "codex 실측: 승인·플랜 승인 화면은 blocked이고 composer에 친 같은 문구는 아니다" {
    // 실측 0.146.1 — 명령 승인. 옵션 줄만 `›`이고 확인 문구는 그 아래 별도 줄이다.
    const command_approval =
        "  Would you like to run the following command?\n" ++
        "  $ printf 'hi' > /Users/u/probe.txt\n" ++
        "› 1. Yes, proceed (y)\n" ++
        "  2. Yes, and don't ask again for commands that start with `printf`\n" ++
        "  3. No, and tell Codex what to do differently (esc)\n" ++
        "\n" ++
        "  Press enter to confirm or esc to cancel";
    // 실측 0.146.1 — `/plan` 승인. 문구가 `… or esc to go back`으로 다르다.
    const plan_approval =
        "  Implement this plan?\n" ++
        "\n" ++
        "› 1. Yes, implement this plan          Switch to Default and start coding.\n" ++
        "  2. Yes, clear context and implement  Fresh thread. Context: 2% used.\n" ++
        "  3. No, stay in Plan mode             Continue planning with the model.\n" ++
        "\n" ++
        "  Press enter to confirm or esc to go back";
    try std.testing.expectEqual(State.blocked, detect(.codex, .{ .screen = command_approval }).state);
    try std.testing.expectEqual(State.blocked, detect(.codex, .{ .screen = plan_approval }).state);

    // composer에 같은 문구를 친 화면. codex composer는 `› 입력` + 빈 행 + 상태줄(상수 2행) 구조라 하단 거리
    // 게이트만으로는 걸러지지 않는다 — `›` 줄 모양으로 배제해야 한다.
    const typed_confirm =
        "• 승인 UI 문구를 정리하겠습니다.\n" ++
        "\n" ++
        "› press enter to confirm or esc to go back 이 어디서 뜨는지 찾아줘\n" ++
        "\n" ++
        "  gpt-5.6-sol · /work/maru";
    const typed_allow =
        "› allow command? 문구를 코드에서 찾아줘\n" ++
        "\n" ++
        "  gpt-5.6-sol · /work/maru";
    try std.testing.expect(detect(.codex, .{ .screen = typed_confirm }).state != .blocked);
    try std.testing.expect(detect(.codex, .{ .screen = typed_allow }).state != .blocked);
}

test "게이트 규칙에도 거리 게이트가 평면 규칙과 같은 의미로 적용된다" {
    // 예전에는 `rule.gate`가 있으면 matchPosition이 곧바로 반환해 `max_lines_from_bottom`이 조용히 무시됐다.
    // 데이터에 값을 적어도 동작하지 않는 함정이라, 평면 규칙을 게이트로 옮기는 것만으로 오버레이 규칙이
    // 현재성을 잃는다(스크롤로 위에 밀린 과거 문구가 계속 blocked를 세운다).
    const rules = [_]Rule{
        .{ .id = "gated_overlay", .state = .blocked, .priority = 100, .region = .screen, .visible_blocker = true, .max_lines_from_bottom = 3, .gate = .{ .contains = &.{"allow command?"} } },
    };
    // 하단 2행 안 → 현재 근거다.
    try std.testing.expectEqual(State.blocked, detectWithRules(&rules, .{ .screen = "Allow command?\n› 1. Yes\n" }).state);
    // 위로 밀린 과거 문구 → 근거가 아니다(거리 게이트가 잘라야 한다).
    const scrolled = "Allow command?\nout1\nout2\nout3\nout4\n› \n";
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = scrolled }).state);

    // 거리는 **가장 위 근거**로 잰다. 아래 근거만 보면 멀리 떨어진 조각을 조합해도 통과한다.
    const spread = [_]Rule{
        .{ .id = "spread_gate", .state = .blocked, .priority = 100, .region = .screen, .visible_blocker = true, .max_lines_from_bottom = 3, .gate = .{ .all = &.{
            .{ .contains = &.{"far above"} },
            .{ .contains = &.{"near bottom"} },
        } } },
    };
    try std.testing.expectEqual(State.unknown, detectWithRules(&spread, .{ .screen = "far above\na\nb\nc\nd\nnear bottom\n" }).state);
    try std.testing.expectEqual(State.blocked, detectWithRules(&spread, .{ .screen = "x\nfar above\nnear bottom\n" }).state);
}

// ── claude 진행 상태줄 (2.1.25x) — `esc to interrupt` 가 사라진 뒤의 유일한 화면 근거

test "claude: 입력창 위의 진행 상태줄이 위치를 이겨 running 을 세운다" {
    // 실측 화면(2.1.252, tmux 안). 진행 줄이 **입력창 위**라 위치 비교로는 프롬프트가 이긴다 —
    // `beats_position` 이 그 가정을 건너뛴다. 이게 없으면 C2 가 훅의 running 을 뒤집는다.
    const screen =
        "✽ Mulling… \n" ++
        "                     ✔\n" ++
        "────────────────────────\n" ++
        "❯ \n" ++
        "────────────────────────\n" ++
        "  maru5 │ main\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
    try std.testing.expect(!d.visible_idle); // ← C2 가 세는 값
}

test "claude: 완료 줄(done)이면 입력창이 idle 을 세운다 — 진행 규칙이 idle 을 통째로 막지 않는다" {
    const screen =
        "✻ Worked for 26s · done 오후 3:41 · 1 shell still running\n" ++
        "────────────────────────\n" ++
        "❯ \n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude: 대화에 남은 옛 Working 텍스트는 진행 신호가 아니다 — 위치 예외를 못 받는다" {
    // 스피너 prefix 가 없으므로 `working_spinner` 에 안 걸리고, 「낡은 footer 아래 새 프롬프트는 idle」
    // 계약이 그대로 산다. 이 구분이 없으면 대화 출력이 배지를 영영 running 으로 묶는다.
    const d = detect(.claude, .{ .screen = "Working… esc to interrupt\nanswer\n❯ " });
    try std.testing.expectEqual(State.idle, d.state);
}

test "claude: 실측된 스피너 프레임 전수가 같은 진행 신호로 읽힌다" {
    for (claude_spinner_frames) |frame| {
        const screen = try std.fmt.allocPrint(std.testing.allocator, "{s} Brewing… \n❯ \n", .{frame});
        defer std.testing.allocator.free(screen);
        const d = detect(.claude, .{ .screen = screen });
        try std.testing.expectEqual(State.running, d.state);
    }
}

test "claude: `…` 없는 스피너 줄은 진행이 아니다 — 완료 줄이 같은 기호를 쓴다" {
    const d = detect(.claude, .{ .screen = "✻ Worked for 3s · done\n❯ " });
    try std.testing.expectEqual(State.idle, d.state);
}
