//! `check-boundaries`의 external source digest 원장 — 데이터 전용 파일이다.
//!
//! 판정 로직은 `imports.zig`가 소유하고 여기에는 **감시 대상과 그 실측값**만 둔다. 원장을 뗀 이유는
//! 충돌 표면 때문이다 — digest는 대상 파일의 비-test 토큰 전체를 잠그므로 그 파일을 건드리는 모든
//! PR이 값을 다시 쓰고, 갱신 사유를 적는 주석이 계속 쌓인다. 그게 `imports.zig` 본체 한가운데
//! 있으면 무관한 판정자 수정과 **인접 hunk 충돌**을 일으킨다(실측: 하루 리베이스 4회, 매번 이 줄).
//!
//! 값 갱신은 `mise run update-boundary-digest`가 한다. 그 도구는 `count`가 바뀌면 갱신을 **거부**하고
//! 멈춘다 — `@field` 반사 접근이 실제로 늘거나 준 것이라 사람이 봐야 한다.
//!
//! **사유 주석은 손으로 쓴다.** 아래 주석 원장이 "이 digest가 왜 또 바뀌었나"의 유일한 기록이고,
//! 특히 `count`가 그대로인 이유를 남기는 자리다. 도구가 대신 지어내지 않는다.

pub const Proof = struct {
    path: []const u8,
    count: usize,
    digest_hex: []const u8,
};
pub const inventory = [_]Proof{
    // 상태바 리소스 표본 seam(resource_samples)이 붙어 바뀐다. count는 3 그대로다 — vtable 항목과 래퍼를
    // 더했을 뿐이고 Client 구성이나 receiver 집합과는 무관하다.
    // OSC 7 authority(`cwd_host`)가 관측 view/owned cache에 실리면서 또 바뀐다. count는 3 그대로다 — 더한 것은
    // 문자열 필드 하나와 그 복사·해제뿐이고, Client 구성이나 receiver 집합과는 무관하다.
    // RuntimeObservation의 일곱 owned buffer가 exact-capacity copy를 쓰고 progress 소비가 backing까지 해제하도록 바뀌었다.
    // import/Client 경계는 그대로라 @field count는 3을 유지한다.
    // 커널 cwd 폴백 seam(`process_cwd`)이 붙어 또 바뀐다(docs/editor-surface-dock.md §3.5 — OSC 7이 없는 셸·TUI에서
    // 활성 터미널의 폴더를 알아내는 경로). count는 3 그대로다 — vtable 항목 하나와 래퍼, fake 구현·계약 테스트를
    // 더했을 뿐이고 `@field` 반사 접근이나 Client 구성·receiver 집합은 건드리지 않는다.
    // io-render-threading.md 분할로 doc comment의 단일 출처 경로가 바뀌어 움직였다(§9 →
    // plans/io-render-threading.md). count는 3 그대로다 — 주석 문자열만 달라졌다. 같은 종류가
    // app_session.zig 항목에도 있다(거기 주석 참조 — 문서가 커지는 한 반복된다).
    // C3-3b5가 공통 close/remove progress enum을 추가했다. 값 타입 선언뿐이라 기존 `@field` 세 곳과 Client receiver는 그대로다.
    // AppSession close 순서를 실제 제품 래퍼에서 검증하는 test-only progress sequence가 붙었다. 제품 vtable과
    // `@field` 세 곳은 그대로이고, 조건부 testing facade 밖의 Client receiver도 늘지 않는다.
    .{ .path = "src/app/term_runtime_backend.zig", .count = 3, .digest_hex = "17ae7e01906456140e04adbc121993e89acfdf4509c785cfb8aaea0a6b86e340" },
    .{ .path = "src/config/schema.zig", .count = 108, .digest_hex = "53943f2f20ec8e47ab22c0eb0c0206869e0ddb26e6ddb57ef02df1b2ae2d34c9" },
    // 브랜치 목록 잡(submitBranches/takeBranchesResult/branchesWorker)이 붙어 바뀐다. count는 2 그대로다.
    // `Backend.deinit`이 in-flight worker를 기다리게 되면서 또 바뀐다(`waitForWorkers`). count는 2 그대로다 —
    // 더한 것은 그 대기 루프 하나뿐이다. 왜 필요한가: `shutting_down`은 새 결과를 버리게 할 뿐 돌고 있는
    // worker를 멈추지 않아, 소유자가 자기 allocator보다 먼저 사라지는 문맥에서 그 worker의 argv 할당이
    // 누수로 잡히고 이어지는 free가 파괴된 allocator를 건드렸다(실측: 누수 2건 + segfault).
    // 코드 리뷰 뒤 **그 대기를 통째로 걷어내며** 또 바뀐다. count는 2 그대로다. 대기는 루트커즈가 아니었다 —
    // 진짜 원인은 "refcount가 객체는 붙들지만 그 객체가 나온 allocator는 못 붙든다"였고, 요구되는 프로세스 수명
    // allocator를 호출자에게 맡겨 두어 테스트가 조용히 어길 수 있었다. 이제 `init`이 인자를 받지 않고
    // `worker_allocator`를 고정하므로 어길 호출자가 없고, 창 닫기는 예전처럼 기다리지 않는다.
    .{ .path = "src/platform/macos/git_backend.zig", .count = 2, .digest_hex = "e7bf4d877f416a39ae241622d618a21ae4a94457889868bcb4ddbce0845f1214" },
    // 모달 오버레이 집합이 `modalInputRole` 역할표에서 파생되면서 `@field(self.chrome_host, ...)` 접근
    // 하나가 제품 경로에 들어왔다(count 3 → 4). 그 reflection은 오버레이 필드를 이름으로 읽는 데만 쓰고
    // 다른 소유권을 만들지 않는다 — 손으로 유지하던 or 체인의 누락(`c822b336`)을 구조적으로 없애는 대가다.
    // CIM2가 divider capture 헬퍼(publish·carry key·tick 소비)와 AppKit E2E probe를 더하면서 digest가
    // 바뀐다. reflection
    // 수는 그대로 4다 — 새 코드는 필드를 이름으로 읽지 않고 live split 포인터만 비교한다.
    // 이어서 Session Dock 키보드 소유권을 `agent_session_dock_key_focus`로 옮기며 다시 바뀐다.
    // 여기서도 count는 4 그대로다 — 새 reflection 없이 제품 토큰만 달라졌다.
    // Session Dock 스크롤 회귀 수정(셰이핑 캐시의 스크롤 기준·뷰포트 clip 전달·submit 시점 origin 배선)으로
    // 다시 digest가 바뀐다. count는 여전히 4다 — 새 코드는 필드를 이름으로 읽지 않고 값만 넘긴다.
    // CIM4b가 탭 드래그 preview를 model 밖 transaction으로 옮기며 또 바뀐다. count는 여전히 4다 —
    // 새 코드(`paneTermOrder`·`paneActiveTermIndex`·`commitTabDragOrder`)는 필드를 이름으로 읽지 않고
    // `*Term` 포인터와 인덱스만 다룬다.
    // scrollbar coalescer를 tick이 소비하게 하며 또 바뀐다. count는 여전히 4다 — 호출 한 줄과 fixture뿐이다.
    // 세션 도크 결함 묶음(텍스트 동기 셰이핑·스크롤바 발행/드래그·도크 view bar 기하)으로 다시 바뀐다.
    // count는 여전히 4다 — 새 코드는 필드를 이름으로 읽지 않는다. 셰이핑은 op 슬라이스와 fingerprint만,
    // 스크롤바는 published rect와 opaque drag payload만, view bar는 `DockMetrics` 값 하나만 다룬다.
    // IC2(아이콘 이름 registry 이관)가 헤더·카드·에이전트 아이콘의 codepoint 리터럴을 `icons.codepoint(...)`/
    // `icons.utf8(...)` 호출로 바꾸며 다시 바뀐다. count는 여전히 4다 — 이름 registry는 생성된 enum 상수라
    // 필드를 이름으로 읽는 reflection이 아니다(`@field` 없음, comptime switch 한 번).
    // IC4(아이콘 크기 토큰)가 헤더 아이콘 배율 상수를 `chrome.ui.icon`으로 옮기며 또 바뀐다. count는 4 그대로다 —
    // 토큰 호출은 값 계산일 뿐 필드를 이름으로 읽지 않는다.
    // 적대적 검증 수선이 `sidebar` → `sidebar_collapse`(그림 이름)로 바꾸며 또 바뀐다. count는 4 그대로다.
    // SV1a(스크롤 좌표계를 `chrome/ui/scroll_area.zig`로 이관)가 props·버퍼 크기 단일 출처 추출과 스크롤
    // 판정자 추가로 또 바꾼다. count는 4 그대로다 — 옮긴 것은 값 계산(높이·offset·버퍼 크기)이고,
    // `ArchiveScrollItems`·`agentSessionDockProps`·`bufferSizes` 어느 것도 필드를 이름으로 읽지 않는다.
    // SV1b의 `ScrollView` → `ScrollArea` 리네이밍이 같은 파일의 타입 참조를 바꾸며 또 바뀐다.
    // count는 4 그대로다 — 이름만 달라졌고 읽는 방식은 그대로다.
    // 렌더 낡음·깜빡임 수선(force_reproject·도크 caret blink·quad 수명/순서·chrome 기하 스탬프·
    // 스크롤바/hit-test lock 계약·placement 실패 가드)으로 또 바뀐다. count는 4 그대로다 —
    // 더한 어느 코드도 필드를 이름으로 읽지 않는다.
    // SV1c가 뷰포트 예측식을 측정 pass로 바꾸고 drag·휠 잔여를 `scroll_area`로 옮기며 또 바뀐다.
    // count는 4 그대로다 — host에서 사라진 것은 값 산술이고, 새로 부르는 `Drag`·`State`도 필드를
    // 이름으로 읽지 않는다.
    // SB1-S2a(상태바 ABI seam)로 또 바뀐다. count는 4 그대로다 — 새 값은 `dock_layout` 권위에서
    // 읽어 스탬프에 싣는 것뿐이고, 필드를 이름으로 읽지 않는다.
    // SV1d(도크 그룹 헤더 sticky)가 걸린 그룹 산출·그룹 DTO 단일 출처·스크롤 텍스트 뷰포트 배선으로
    // 또 바뀐다. count는 4 그대로다 — `archiveStickyGroupFor`는 entry union을 switch로 보고,
    // `agentSessionDockGroupItem`은 필드를 이름이 아니라 값으로 옮긴다.
    // SB1-S2b(상태바 높이 flip)로 또 바뀐다. count는 4 그대로다 — 더한 코드는 높이를 빼거나 quad를
    // 하나 더할 뿐이고, 필드를 이름으로 읽지 않는다.
    // SB1-S3b(상태바 브랜치 항목)로 또 바뀐다. count는 4 그대로다 — 항목 수집은 기존 collectShaped
    // 경로에 dest 하나를 더한 것뿐이고, 필드를 이름으로 읽지 않는다.
    // SV2-0(탐색기 스크롤 판정자)이 그리는 창을 `fileTreeDrawWindow`로, clamp를 `clampFileTreeScroll`로
    // 꺼내며 또 바뀐다. count는 4 그대로다 — 둘 다 정수만 계산하고 필드를 이름으로 읽지 않는다.
    // SB1-S3c(상태바 cwd 항목)로 또 바뀐다. count는 4 그대로다 — 항목을 배열로 모으고 배치에
    // 넘기는 것뿐이고, 필드를 이름으로 읽지 않는다.
    // SB1-S3d(상태바 알림 항목 + 헤드리스 검증 훅)로 또 바뀐다. count는 4 그대로다 — 우측 배열을
    // 하나 더 넘기는 것뿐이고, 필드를 이름으로 읽지 않는다.
    // SV2a-2(탐색기 pane을 role로 표시하고 clip을 실어 v147 seam의 첫 소비자가 된다)로 또 바뀐다.
    // count는 4 그대로다 — 더한 것은 bool 하나와 rect 전달뿐이고 필드를 이름으로 읽지 않는다.
    // SB1-S3e(상태바 에이전트 항목 + 검증 훅)로 또 바뀐다. count는 4 그대로다.
    // 상태바 높이를 텍스트 행 + 여백에서 파생하며 또 바뀐다. count는 4 그대로다.
    // 사이드바 scissor 산술을 `.m`에서 Zig로 옮기며 또 바뀐다(ABI v168). count는 4 그대로다.
    // SV2a-3(탐색기 스크롤 상태를 행에서 픽셀로)으로 또 바뀐다. count는 4 그대로다 — 바뀐 것은 탐색기
    // 스크롤 좌표계와 그 소비처들이고, Client 구성이나 receiver 집합과는 무관하다.
    // 상태바를 typed tree 소비자로 만들며(hover·클릭) 또 바뀐다. count는 4 그대로다.
    // SV2b(탐색기 스크롤바를 공용 ScrollArea/paint 경로로 이관)로 또 바뀐다. count는 4 그대로다 —
    // 바뀐 것은 스크롤바의 발행·paint 경로이고 Client 구성이나 receiver 집합과는 무관하다.
    // SV3a(소스 컨트롤 목록을 픽셀 스크롤로, 헤더/목록 draw list 분리)로 또 바뀐다. count는 4 그대로다.
    // 도크 진입 seam 분리(`enterDockView`/`onDockViewPresented`/`shouldRefreshArchiveOnPresent`)와 아카이브
    // `partial` DTO 노출로 또 바뀐다. count는 4 그대로다 — 더한 것은 진입 훅과 스캐너 신호 전달뿐이고,
    // Client 구성이나 receiver 집합과는 무관하다.
    // 세션 카드의 서브에이전트 개수 표시로 또 바뀐다. count는 4 그대로다 — 스캐너가 센 값을 메타 문구에
    // 잇는 것뿐이다.
    // 세션 재개를 로그인 셸 경유로 바꾸며 또 바뀐다(`buildResumeShellCommand`). count는 4 그대로다 —
    // spawn request의 command/args를 다르게 채울 뿐 Client 구성과는 무관하다.
    // AS5(스트리밍 파서 + read cap 제거 + 점진 publish)로 또 바뀐다. count는 4 그대로다 — 결과 종류를
    // union으로 정리하고 부분 진행을 다루는 분기가 늘었을 뿐이다.
    // 상태바 blocked 항목·typed tree 상호작용으로 또 바뀐다. count는 4 그대로다.
    // 선택 해제 전이(⌘A 하이라이트가 트래킹 pane에서 안 지워지던 결함 — `clearSurfaceSelection`을 리포팅
    // 클릭·휠·타이핑·Esc에 배선)로 또 바뀐다. count는 4 그대로다 — 더한 것은 `select_clear` 명령 enqueue
    // 하나와 그 호출들뿐이고, Client 구성이나 receiver 집합과는 무관하다.
    // v169(셀이 자기 clip을 든다 — PaneFrameRole.dock_list 제거)로 또 바뀐다. count는 4 그대로다.
    // SV3b(소스 컨트롤 스크롤바 신규 + 발행 상태를 dock_list_scroll_*로 공유)로 또 바뀐다. count는 4 그대로다.
    // 상태바 경로 항목이 컴포넌트 단위 생략을 타면서 또 바뀐다. count는 4 그대로다.
    // SV4a(사이드바 스크롤바를 선언된 tree로 이관 + gutter 상시 예약)로 또 바뀐다. count는 4 그대로다.
    // SV4b(사이드바 스크롤바 드래그 — capture·drag는 공유하고 대상만 태그)로 또 바뀐다. count는 4 그대로다.
    // SV4b 후속(스크롤바 layer 3 복원 + hover 게이트)으로 또 바뀐다. count는 4 그대로다.
    // 사이드바 스크롤바 hover 강조(커서는 안 바꾸고 alpha만)로 또 바뀐다. count는 4 그대로다.
    // 사이드바 셀 scissor 게이트 수정(밴드 배열 → 실제로 그릴 셀이 있는가)으로 또 바뀐다. count는 4 그대로다.
    // 상태바 브랜치 메뉴(요청·걷기·선택 주입)로 또 바뀐다. count는 4 그대로다.
    // 상태바 브랜치 메뉴(요청·걷기·선택 주입)로 또 바뀐다. count는 4 그대로다.
    // 도크 진입 seam 분리(`enterDockView`/`onDockViewPresented`/`shouldRefreshArchiveOnPresent`)와 아카이브
    // `partial` DTO 노출로 또 바뀐다. count는 4 그대로다 — 더한 것은 진입 훅과 스캐너 신호 전달뿐이고,
    // Client 구성이나 receiver 집합과는 무관하다.
    // 세션 카드의 서브에이전트 개수 표시로 또 바뀐다. count는 4 그대로다 — 스캐너가 센 값을 메타 문구에
    // 잇는 것뿐이다.
    // 세션 재개를 로그인 셸 경유로 바꾸며 또 바뀐다(`buildResumeShellCommand`). count는 4 그대로다 —
    // spawn request의 command/args를 다르게 채울 뿐 Client 구성과는 무관하다.
    // 상단 바 통일(터미널 탭 바 = 도크 뷰 스위처)로 또 바뀐다. 높이는 공유 chrome token `space.bar_height_pt`가,
    // 시작선은 `titlebar_strip_px` 하나가 정한다(도크 전용 `dock_top_px` 제거). 둘 다 terminal cell을 `@max`로도
    // 섞지 않는다 — 섞었더니 `font-scale-rects` fixture가 14pt↔24pt 도크 rect 12px 이동을 잡아냈다. count는 4
    // 그대로다: `chromeBarHeightPx`·`chromeBarTextOffsetY`는 토큰 값과 rect 높이로 산술만 하고, 시작선 쪽은
    // 입력 필드 하나를 뺀 것이라 어느 쪽도 필드를 이름으로 읽지 않는다.
    // 브랜치 메뉴 앵커 게이트로 또 바뀐다. count는 4 그대로다.
    // 사이드바 카드 ✕의 열 배치를 chrome 단일 출처(`sidebar.columns`)로 올리며 또 바뀐다. count는 4 그대로다 —
    // 새 헬퍼(`sidebarColumns`·`sidebarCloseButtonAt`)는 토큰 값을 chrome 함수에 넘기고 그 결과로 산술만 하며,
    // 필드를 이름으로 읽지 않는다.
    // SV5b(팔레트 스크롤바를 공용 발행 경로로 — 상태는 안 만든다)로 또 바뀐다. count는 4 그대로다.
    // AS6(정렬 키·방향 토글)로 또 바뀐다. count는 4 그대로다.
    // 아카이브 스캔 스트리밍 이관(점진 publish 요청 플래그)으로 또 바뀐다. count는 4 그대로다.
    // 웹 탭 ⌘F 라우팅 게이트로 또 바뀐다. count는 4 그대로다.
    // Chrome 텍스트 face를 사용자 `font.family`로 넘기며 또 바뀐다(docs/font-strategy.md "Chrome 텍스트
    // face"). count는 4 그대로다 — resolved appearance의 두 문자열을 셰이핑 요청에 실어 보낼 뿐이고,
    // Client 구성이나 receiver 집합과는 무관하다.
    // SV5c(세팅 스크롤바 + 오버레이 발행 공통화)로 또 바뀐다. count는 4 그대로다.
    // SV5d(오버레이 휠·드래그 + offset 상태 도입)로 또 바뀐다. count는 4 그대로다.
    // SV5d(오버레이 휠·드래그 + offset 상태 + 값 비교 selection follow)로 또 바뀐다. count는 4 그대로다.
    // 웹 탭 페이지 찾기(§8 슬라이스 ② — take/provide/undeliverable 3종)로 또 바뀐다. count는 4 그대로다.
    // 사이드바 헤더를 신호등 띠 + 상단 바 두 밴드로 정렬하며 또 바뀐다(docs/file-explorer.md §3.5). count는 4
    // 그대로다 — 헤더 높이·밴드 y를 푸는 순수 헬퍼와 draw list 분리뿐이고, Client 구성·receiver 집합과는 무관하다.
    // `reapplyAmbiguousWidth`의 빈 lockCore/unlockCore 쌍을 제거하며 또 바뀐다. count는 4 그대로다 —
    // 죽은 락 두 줄을 지웠을 뿐 `@field` 접근과 무관하다.
    // `handleKeyEvent`의 라우팅 분기 21개가 공유하던 key-down 종결부를 헬퍼 3개
    // (`settleKeyEventSummary`·`keyConsumedByApp`·`keyIgnored`)로 모으며 또 바뀐다. count는 4 그대로다 —
    // 종결부는 요약 필드에 값을 쓸 뿐이고 Client 구성이나 `@field` 접근과 무관하다.
    // `mouse`의 진행 중 포인터 제스처 라우팅 9블록을 `routeActivePointerGesture`로 떼어내며 또 바뀐다.
    // count는 4 그대로다 — 블록을 통째로 옮겼을 뿐 `@field` 접근을 더하거나 빼지 않는다.
    // `tick`의 지연 포인터 입력 적용·pre housekeeping·Find 뷰포트 span 계산을 각각 함수로 떼어내며 또
    // 바뀐다. count는 4 그대로다 — 블록 이동일 뿐 `@field` 접근과 무관하다.
    // measured 텍스트 캐시를 소비처별 슬롯 + 공용 헬퍼(hit/store/clear)로 일반화하며 또 바뀐다
    // (docs/file-explorer.md §3.5 이관 1단계). count는 4 그대로다 — 캐시 소유권 규칙을 한곳에 모은 것뿐이고,
    // Client 구성·receiver 집합과는 무관하다.
    // SV6a(공용 lowering이 layer를 받는다 — 소비처의 되돌리기 제거)로 또 바뀐다. count는 4 그대로다.
    // 웹 find 결과의 죽은 사본(`web_find_result`)을 지우며 또 바뀐다. count는 4 그대로다 — 읽는 곳이
    // 없던 필드를 뺀 것뿐이고, Client 구성·receiver 집합과는 무관하다.
    // 사이드바 검색 줄 텍스트를 measured 경로로 옮기며 또 바뀐다(이관 2단계, docs/file-explorer.md §3.5).
    // count는 4 그대로다 — 검색 텍스트의 rect·문자열·수집 헬퍼를 더한 것뿐이고 Client 구성과는 무관하다.
    // 탭 제목 텍스트를 measured 경로로 옮기며 또 바뀐다(이관 3단계). count는 4 그대로다 — 마커/본문 분리
    // 헬퍼와 제목 발행 함수를 더한 것뿐이고, Client 구성·receiver 집합과는 무관하다.
    // 탭 제목의 세로 위치를 role line box 기준으로 고치며 또 바뀐다(24pt 캡처가 잡은 어긋남). count는 4
    // 그대로다 — 바 rect에서 중앙을 푸는 산술뿐이고, Client 구성·receiver 집합과는 무관하다.
    // 에이전트 세션 기록 도크(archive + agent dock)를 `app_session/agent_dock.zig`로 떼어내며 또 바뀐다.
    // count는 4 그대로다 — 옮긴 블록에 `@field` 접근이 없고, 공용 accessor 13개를 pub으로 연 것뿐이다.
    // 파일 탐색기·파일 패널을 `app_session/file_panel.zig`로 떼어내며 또 바뀐다(F2). count는 4 그대로다 —
    // 옮긴 블록에 `@field` 접근이 없고, 공용 accessor 50개를 pub으로 연 것뿐이다.
    // SV5a-2(알림 막대를 공용 발행 경로로 — 손수 그린 복제본 제거)로 또 바뀐다. count는 4 그대로다.
    // pane·split·divider를 `app_session/pane.zig`로 떼어내며 또 바뀐다(F4). count는 4 그대로다 —
    // 옮긴 블록에 `@field` 접근이 없고, 공용 accessor 43개를 pub으로 연 것뿐이다.
    // 알림 배지 원의 세로 원점을 `sidebarHeaderIconRowTopPx`로 고치며 또 바뀐다. count는 4 그대로다 —
    // 헤더 아이콘 줄 원점을 뽑은 헬퍼와 상수뿐이고, Client 구성·receiver 집합과는 무관하다.
    // 도크 일반(view·레이아웃·스크롤바)을 `app_session/dock.zig`로 떼어내며 또 바뀐다(F5). count는 4
    // 그대로다 — 옮긴 블록에 `@field` 접근이 없고, 공용 accessor 4개를 pub으로 연 것뿐이다.
    // 탭(생성·전환·이동·고정·그룹·제목)을 `app_session/tab.zig`로 떼어내며 또 바뀐다(F6). count는 4
    // 그대로다 — 옮긴 블록에 `@field` 접근이 없고, 공용 accessor를 열고(41) 옮겨간 탭 함수 pub을 닫은
    // 것뿐이다. 그룹 파일끼리 `app_session.zig` 재수출을 거치던 참조도 직접 `@import`으로 바꿨다.
    // 상태바 리소스 항목(표본 폴링·표시 캐시·항목 추가)이 붙어 바뀐다. count는 4 그대로다.
    // 사이드바(행 모델·스크롤·드래그 프리뷰·카드·헤더)를 `app_session/sidebar.zig`로 떼어내며 또
    // 바뀐다(F7). count는 4 그대로다 — 옮긴 블록에 `@field` 접근이 없고, 공용 accessor를 열고(44)
    // 옮겨간 사이드바 함수 pub을 닫은 것뿐이다. 탭 그룹 모델 240줄은 소유가 tab이라 옮기지 않았다.
    // 스크롤 기구(휠·페이지 라우팅, 스크롤바 위젯, 오버레이)를 `app_session/scroll.zig`로 떼어내며 또
    // 바뀐다(F8). count는 4 그대로다 — 옮긴 블록에 `@field` 접근이 없고, 공용 accessor를 열고(25) 옮겨간
    // 스크롤 함수 pub을 닫은 것뿐이다. ABI가 부르는 scrollPage·scrollWheel은 얇은 facade로 남겼다.
    // 세팅·컨텍스트 메뉴·이름 변경·config 적용을 `app_session/settings.zig`로 떼어내며 또 바뀐다(F9).
    // **여기서 처음으로 count가 움직인다(4 → 2).** F1~F8은 옮긴 블록에 `@field`가 없어 count가 4로
    // 고정이었는데, F9는 `pending_writeback_lists`를 이름으로 도는 반사 접근 둘(config write-back 목록의
    // 비우기·비어있음 판정)을 함께 데려갔다. 반사가 늘거나 준 것이 아니라 **소유 파일이 바뀐 것**이라
    // 아래에 `app_session/settings.zig` 항목을 같은 수(2)로 새로 등재한다 — 합은 4로 보존된다.
    // 남은 둘은 `@field(self.chrome_host, field.name)`(모달 오버레이 역할표)과 같은 목록의 deinit이다.
    // pane 탭 제목 발행을 pane마다에서 프레임당 한 번으로 옮기며 또 바뀐다(단일 슬롯 캐시를 pane마다
    // store해 앞 pane 아티팩트가 해제되던 use-after-free 수정). count는 F9가 옮긴 뒤의 2 그대로다 —
    // 바뀐 것은 pane 루프 배선 3줄(batch 선언·append 호출·루프 뒤 flush)뿐이고 Client 구성·receiver
    // 집합과는 무관하다.
    // workspace·window(캡처/복원/이동, 창 속성)를 `app_session/workspace.zig`로 떼어내며 또 바뀐다(F10).
    // count는 2 그대로다 — 옮긴 블록에 `@field`가 없다. F9에서 이사한 둘은 settings.zig에 그대로 있다.
    // SV6b(오버레이 over quad를 프레임 끝에 한 덩어리로 flush)와 시각 검증용 MARU_FORCE_STICKY 훅으로 또
    // 바뀐다. count는 2 그대로다 — 더한 것은 대기 버퍼 하나와 그 flush 호출, core에 바이트를 쓰는 훅뿐이고,
    // 어느 것도 필드를 이름으로 읽지 않는다.
    // web panel·인앱 브라우저를 `app_session/web.zig`로 떼어내며 또 바뀐다(F11). count는 2 그대로다 —
    // 옮긴 블록에 `@field`가 없다. ABI가 부르는 20개는 얇은 facade로 남겼다.
    // 키 입력·IME·키바인딩을 `app_session/input.zig`로 떼어내며 또 바뀐다(F12). count는 2 그대로다 —
    // 옮긴 블록에 `@field`가 없다. ABI가 부르는 11개는 얇은 facade로 남겼다.
    // 알림·벨을 `app_session/notification.zig`로 떼어내며 또 바뀐다(F13). count는 2 그대로다 —
    // 옮긴 블록에 `@field`가 없다. ABI가 부르는 5개는 얇은 facade로 남겼다.
    // 스크롤바 잡는 폭을 gutter 전체로 넓히며(그리는 폭과 분리) 또 바뀐다. count는 2 그대로다 —
    // 더한 것은 거터 상수 값 하나뿐이고, 필드를 이름으로 읽지 않는다.
    // 에이전트 관측을 `app_session/agent.zig`로 떼어내며 또 바뀐다(F14). count는 2 그대로다 —
    // 옮긴 블록에 `@field`가 없다. 세션 기록 도크(F1)의 ABI facade 10개는 이름이 agent여도 두고 왔다.
    // git·SCM을 `app_session/git.zig`로 떼어내며 또 바뀐다(F15). count는 2 그대로다 — 옮긴 블록에
    // `@field`가 없다. `scmDrawWindow`는 이름만 SCM이고 dock(F5)의 facade라 두고 왔다.
    // term·surface를 `app_session/term.zig`로 떼어내며 또 바뀐다(F16). count는 2 그대로다 — 옮긴
    // 블록에 `@field`가 없다. 소유권 게이트(CR3a-1)가 파일 단위로 고정한 `RemoteSessionAdapter.initInPlace`
    // 호출자 3개는 게이트를 느슨하게 하는 대신 허브에 남겼다.
    // 한 그룹만 쓰는 파일 레벨 헬퍼 65개를 각 그룹 파일로 함께 옮기며 바뀐다. count는 2 그대로다 —
    // 옮긴 블록에 `@field`가 없다. 이 작업으로 허브 pub이 621 → 557로 **줄었다**(F 시리즈 이래 처음).
    // F6 보정(탭 그룹 모델 16개를 `tab.zig`로)으로 또 바뀐다. count는 2 그대로다 — 옮긴 블록에
    // `@field`가 없고, F6가 열었던 pub 10개가 닫혔다.
    // 디버그 픽스처 하네스(`maybeDebugOpenSettings`·`maybeDebugOpenFilePanel`)를
    // `app_session/debug_fixtures.zig`로 빼며 또 바뀐다. count는 2 그대로다 — 옮긴 블록에 `@field`가 없다.
    // 호출 그래프로 소유를 확인한 46개(+파일 레벨 7개)를 각 그룹으로 옮기며 또 바뀐다. count는 2
    // 그대로다 — 옮긴 블록에 `@field`가 없고, ABI가 부르는 17개는 얇은 facade로 남겼다.
    // 원격 cwd 판정(`localHostname`·`termCwdIsRemote`)과 그 소비처(폴더줄 host 접두·`linkScopesForTerm`)가 붙어
    // 또 바뀐다. count는 2 그대로다 — 새 코드는 관측 캐시의 문자열을 값으로 비교할 뿐 필드를 이름으로 읽지 않는다.
    // 커널 cwd 폴백 캐시 필드(`proc_cwd_*`)와 소스 컨트롤 저장소 판정 회귀 테스트 둘이 붙어 또 바뀐다.
    // count는 2 그대로다 — 더한 것은 인라인 버퍼/스칼라 필드와 테스트뿐이고 `@field` 반사는 없다.
    // 적대적 검증에서 폴백 캐시를 tick 카운터 → awake clock 시각으로 바꾸고(한 프레임에 여러 번 불리는 경로라
    // 카운터로는 주기가 안 지켜졌다) 탐색기 root·diff 열림 회귀 단언을 더하며 또 바뀐다. count는 2 그대로다.
    // 코드 리뷰 뒤 walk-up 캐시 필드와 원격 세션 회귀 테스트가 붙고, diff 본문 두 쪽을 backend allocator로
    // 해제하도록 고치며 또 바뀐다(그 두 버퍼만 `DiffResult`에서 소유권을 넘겨받은 것이라 세션 allocator로
    // 풀면 heap이 깨진다 — 실측: Invalid free). count는 2 그대로다.
    // C3-3b5 window close가 확인 수락 뒤에도 runtime progress를 tick에서 재시도하도록 latch와 제품 테스트를
    // 추가했다. 이름 기반 필드 접근은 건드리지 않아 `@field` count는 2 그대로다.
    // final-address remote backend singleton claim의 exact 두 제품 caller와 rollback을 추가했다. 이 경로도
    // 직접 필드 접근만 사용하므로 `@field` count는 2 그대로다.
    // **문서 분할이 이 항목을 반복해 움직인다.** 이 파일의 doc comment가 단일 출처 문서를 경로로 적고 있어,
    // 그 문서를 가를 때마다 문자열이 바뀐다(file-panel·sidebar-groups·agent-session-list·metal-ui-layout에서
    // 차례로 겪었다 — 여기까지 네 번이고, 문서가 커지는 한 또 온다). 매번 count는 2 그대로인데, `@field` 반사도
    // 선언도 손대지 않고 주석 문자열만 달라지기 때문이다. 개별 이력은 git이 가지므로 사유를 여기 쌓지 않는다.
    // 사이드바 세션 목록이 에이전트 전수에서 **Term 전수**(터미널·브라우저·파일)로 넓어지고, 종류 아이콘이
    // 왼쪽 gutter에서 이름줄 인라인으로 옮겨가며 또 바뀐다(docs/sidebar-agent-list.md §1·§2). count는 2 그대로다 —
    // `WorkspaceAgent` → `WorkspaceSession` 개명, 테스트 둘(신규 1 + 기존 1 보정), `buildSidebarDrawList`에
    // `inline_icons` 인자가 붙은 호출부 둘뿐이고, 전부 평범한 타입·인자 전달이라 `@field` 반사와 무관하다.
    // file-panel.md 분할로 주석 여섯 곳의 단일 출처 경로가 바뀌어 움직였다(§2.2·§2.6 → file-panel-kinds.md,
    // §2.3·§2.4 → file-panel-web-stack.md, §2.5 → file-panel-rich-edit.md, §3.4 → file-panel-dock-ui.md).
    // count는 2 그대로다 — `@field` 반사도 선언도 손대지 않았고 바뀐 것은 주석 문자열뿐이다.
    // sidebar-groups.md 분할로 주석의 단일 출처 경로가 바뀌어 움직였다(§9 → plans/sidebar-groups.md,
    // §12~§13 → sidebar-groups-pinning.md, §14 → sidebar-groups-top-level.md).
    // count는 2 그대로다 — `@field` 반사도 선언도 손대지 않았고 바뀐 것은 주석 문자열뿐이다.
    // agent-session-list.md 분할로 doc comment의 단일 출처 경로가 바뀌어 움직였다(§2.1.3 →
    // agent-session-list-layout.md). count는 2 그대로다 — 주석 문자열만 달라졌다.
    // ET-CWD가 root 밖 cwd에서 **root를 갈아끼우게** 되며 또 바뀐다(2026-08-11 사용자 결정 —
    // docs/file-explorer.md §1). 자동 전환 표시 필드(`auto`·재시도 one-shot)와 회귀 단언을 더했을 뿐
    // `@field` 반사는 없다. count는 2 그대로다.
    // 적대적 검증에서 전환 커밋 뒤 한 번 더 reveal하는 one-shot 필드가 붙어 또 바뀐다(깊은 하위
    // 디렉터리에서 트리가 저장소 루트에 접힌 채 멈추던 것). count는 2 그대로다.
    // ET-CWD가 root 밖 cwd에서 **root를 갈아끼우게** 되며 또 바뀐다(2026-08-11 사용자 결정 —
    // docs/file-explorer.md §1). 자동 전환 표시 필드(`auto`·재시도 one-shot)와 회귀 단언을 더했을 뿐
    // `@field` 반사는 없다. count는 2 그대로다.
    // C3-3b5가 Term별 close generation/reservation과 AppSession inline close graph를 추가했다. 기존 reflection
    // 두 곳과 그 대상은 바뀌지 않았고, 새 권위는 별도 process-sealed leaf가 검증한다.
    // 창 닫기 graph의 scalar 저장 형식을 Linux ABI 교차 빌드에도 유지하도록 조건부 void 별칭을 없앴다.
    // 읽는 reflection 두 곳은 그대로이고, syscall과 RemoteRuntime 실행 경로는 계속 macOS에만 남는다.
    // b4는 frame 시작의 backend pump와 실제 async close parity 테스트만 더하며 기존 반사 owner 둘은 유지한다.
    // C3-3b6 app-quit 제품 순서와 실제 socket fixture가 추가됐지만 기존 반사 두 곳의 소유 범위는 그대로다.
    // 마지막 target 승인 frame을 즉시 반환해 terminal Runtime의 같은-frame 재접근을 막는 순서까지 digest에 포함한다.
    // 소스 컨트롤 저장소 판정이 3-상태(`RepoTarget`)로 갈리고, 브랜치 표시가 `.git` 변경 이벤트로 갱신되도록
    // 바뀌며 또 움직인다(docs/editor-surface-dock.md §3.5 "판정은 3-상태다" · docs/status-bar.md 브랜치 항목).
    // count는 2 그대로다 — 더한 것은 `fileTreeChanged`의 `.git` 분기 호출 한 줄, `MARU_FORCE_SCM` self-verify
    // 게이트(`getenv` + `openDockTo`), 그리고 테스트 셋이다. 전부 평범한 호출·값 전달이라 `@field` 반사 접근이나
    // Client 구성·receiver 집합과는 무관하다.
    // 커널 cwd 폴백 캐시가 AppSession 단일 슬롯에서 **Term별**(`TermRuntime.proc_cwd_*`)로 옮겨 가고,
    // `sidebarCwdPath`가 관측 직독 대신 `git_ops.termCwdForDisplay`를 쓰게 되며 바뀐다(docs/editor-surface-dock.md
    // §3.5의 2단 규칙을 사이드바까지 확장 — 그전까지 OSC 7이 없는 Term에서 소스 컨트롤은 저장소를 찾는데
    // 사이드바만 폴더·브랜치줄을 지웠다). count는 2 그대로다 — 옮긴 것은 값 필드 셋과 그 읽기뿐이고,
    // `@field` 반사 접근이나 Client 구성·receiver 집합은 건드리지 않는다.
    // 같은 PR의 후속 커밋 둘로 또 바뀐다. ⑴ 상태바 빈 구간 테스트가 "바 한가운데는 비어 있다"는 가정을
    // 버리고 발행된 tree에서 빈 x를 찾도록 바뀌었고(그 가정은 cwd를 모르던 시절의 우연이라 커널 폴백이
    // 들어오자 부하에 따라 통과/실패가 갈렸다), ⑵ 사이드바 재투영 가드가 카드 행뿐 아니라 **에이전트 행**의
    // 줄 수도 보게 됐다(제품 스크린샷에서 폴더줄이 다음 행 라벨을 덮는 것을 확인 — cwd가 투영 뒤에 도착하는
    // 경로가 커널 폴백으로 흔해졌다). count는 2 그대로다 — 더한 것은 테스트와 판정 한 갈래뿐이고 `@field`
    // 반사 접근이나 Client 구성·receiver 집합은 건드리지 않는다.
    .{ .path = "src/platform/macos/app_session.zig", .count = 2, .digest_hex = "463a1178d7f2cd6c7311d566ffe34f5b5b2b0d52bbc31cac150a3dfa8dd00a58" },
    // F9로 `app_session.zig`에서 넘어온 `pending_writeback_lists` 반사 둘이 여기 산다. 새로 생긴 반사가
    // 아니라 이사한 것이다(위 app_session.zig 항목의 4 → 2와 짝이다).
    // F10에서 그룹 간 참조를 허브 재수출 대신 직접 `@import`으로 바꾸며 digest가 바뀐다. count는 2
    // 그대로다 — 반사 접근은 손대지 않고 import 줄만 달라졌다.
    // F11에서 web 함수 alias를 허브 경유 대신 직접 `@import`으로 바꾸며 digest가 바뀐다. count는 2 그대로다.
    // F12에서 `chromeInputFromKeyEvent` alias를 직접 `@import`으로 바꾸며 digest가 바뀐다. count는 2 그대로다.
    // F14에서 agent 함수 alias를 직접 `@import`으로 바꾸며 digest가 바뀐다. count는 2 그대로다.
    // F15에서 git 함수 alias를 직접 `@import`으로 바꾸며 digest가 바뀐다. count는 2 그대로다.
    // 리소스 팝오버(탭별 행 조립·앵커·클릭 점프)가 붙어 바뀐다. count는 4 그대로다.
    // F9가 `app_session.zig`에서 옮긴 반사 둘이 여기 산다(위 항목의 4 → 2와 짝) — 위 주석이 "등재한다"고
    // 했는데 항목이 없어, 리소스 팝오버가 이 파일을 건드리자 미등재로 걸렸다.
    // F9가 `app_session.zig`에서 옮긴 반사 둘이 여기 산다(위 항목의 4 → 2와 짝). 이 항목이 **빠져 있어**
    // 리소스 팝오버가 이 파일을 건드리자 미등재로 걸렸다 — 이사한 반사를 여기 등재해 짝을 맞춘다.
    // F9가 `app_session.zig`에서 옮긴 반사 둘이 여기 산다(위 항목의 4 → 2와 짝). 위 주석이 "등재한다"고
    // 했는데 항목이 없어, 리소스 팝오버가 이 파일을 건드리자 미등재로 걸렸다.
    // git backend가 프로세스 수명 allocator를 스스로 고정하면서 `Backend.init`이 인자를 잃어 호출부가 바뀐다.
    // count는 2 그대로다 — 호출 한 줄뿐이고 반사 접근은 건드리지 않았다.
    // 편집기 설정 섹션(`editor.wrap` 랩 토글)이 붙어 바뀐다. count는 2 그대로다 — 더한 것은
    // `settingsSectionLabel`의 분기 한 줄("편집기")뿐이고, 필드를 이름으로 읽지 않는다.
    // view options(⚙) 메뉴에 세션 아이콘 배치 토글(`sidebar.session-icon-gutter`)이 붙어 바뀐다. count는 2
    // 그대로다 — 항목 문자열 하나와 토글 분기 하나를 더했을 뿐 필드를 이름으로 읽지 않는다.
    // view options(⚙) 메뉴에 세션 아이콘 배치 토글(`sidebar.session-icon-gutter`)이 붙었다가 **되돌려졌다** —
    // 두 배치를 옵션으로 남기는 대신 인라인 하나로 확정했기 때문이다(사용자 결정). 그래서 값이 토글 도입
    // 이전으로 돌아왔다. count는 내내 2 그대로였다.
    .{ .path = "src/platform/macos/app_session/settings.zig", .count = 2, .digest_hex = "1c0783521f3ef6495bbcab342afa71a4a6d174fdd5ceee97f900a7d2d70a5469" },
    // 같은 분할로 주석 둘의 경로가 바뀌어 움직였다(§2.2 → file-panel-kinds.md, §3.2 → file-panel-dock-ui.md).
    // count는 1 그대로다 — 주석 문자열만 달라졌다.
    // editor-surface.md 분할로 doc comment의 단일 출처 경로가 바뀌어 움직였다(§3 →
    // editor-surface-structure.md, §9 → plans/editor-surface.md). count는 1 그대로다 — 주석 문자열만 달라졌다.
    .{ .path = "src/session/dock_panel.zig", .count = 1, .digest_hex = "0f097f6549b745484f6decde55037ab082b1b8e2b7e12dbb34c5fd5d52a2139c" },
    // control-plane.md 분할로 모듈 주석의 단일 출처 경로가 바뀌어 움직였다(§4.1·§4.3 → control-plane-protocol.md,
    // §16 → control-plane-implementation.md). digest는 비-test 토큰 전체를 잠그므로 주석만 고쳐도 값이 바뀐다.
    // count는 1 그대로다 — `@field` 반사는 늘지도 줄지도 않았고 선언은 한 줄도 안 건드렸다.
    .{ .path = "src/session/control_plane.zig", .count = 1, .digest_hex = "b86809f9b52d6fc794ef73387b65eac18dc48d179c8ed00ca58f7cc9c3fa33eb" },
    .{ .path = "src/session/workspace.zig", .count = 1, .digest_hex = "d15b62332c9e7f47f421161958b07370924ffa4cefacf1203255160c2ea421dc" },
};
