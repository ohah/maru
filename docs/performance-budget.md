# 성능 예산

성능 예산은 Maru가 "작고 빠른 native shell"이라는 목표를 실제 숫자로 추적하기 위한 기준이다. 이 문서는 벤치마크 점수를 자랑하기 위한 문서가 아니라, 기능을 추가할 때 느린 구조가 조용히 들어오지 않게 막는 안전장치다.

이 문서는 "느려졌나?"(통과/실패 guardrail)를 담당한다. 예산이 깨졌을 때 "어디가 왜 느린지"를 책임 경계별 계측과 프로파일러로 좁히는 방법은 [프로파일링 전략](profiling.md)을 단일 출처로 둔다.

## 원칙

- 기본 `mise run check`에는 성능 측정을 넣지 않는다. 하드웨어와 시스템 부하에 따라 결과가 흔들릴 수 있기 때문이다.
- `mise run perf`는 로컬 opt-in 명령이다. 큰 구조 변경 전후에 실행한다.
- GitHub `Performance` workflow는 코드가 바뀐 PR([변경 영역별 실행](#변경-영역별-실행job-level-게이트)의 `code` 축), `main` push, 수동 실행, 주간 schedule에서 돌고 **PR required check로 쓴다**. reflow perf 회귀가 PR 체크에 없어 main에 들어간 일이 있어 PR 게이트로 승격했다(`.github/workflows/performance.yml` 주석 참조). GitHub hosted runner의 부하가 숫자를 흔드는 문제는 예산에 여유를 둬(다른 벤치와 같은 2s급 상한) 흡수하고, 구조 회귀(2배+)만 잡는다.
- 초기에 걸어두는 숫자는 보수적인 guardrail이다. 정확한 목표치는 macOS app, PTY, renderer가 붙은 뒤 다시 조정한다.
- 성능 실패는 숫자만 보고 고치지 않는다. 어떤 책임 경계가 느린지 trace/snapshot/artifact로 확인한 뒤 루트커즈를 고친다.
- **`zig build test` 안의 벽시계 단언은 "재앙 감지선"이고, 선은 실측 두 값 사이에 둔다** — 지금 값과, 그것이 잡겠다는 회귀의 값. 둘 다 주석에 적는다. 한쪽만 보면 양쪽으로 어긋난다(2026-08-18에 둘 다 겪었다):
  - **너무 빡빡하면** 감지선이 아니라 동전 던지기다. `editor.zig`의 "가장 긴 줄 세기"가 실측 373ms(로컬 Debug)에 선이 500이었고, CI 러너가 더 느려 **501ms**를 내며 main을 반반으로 흔들었다. 배포가 쓰는 ReleaseFast에서는 42ms라 **제품이 느린 것이 아니었다** — Debug를 CI에서 돌린 값을 기준으로 잡아야 했다.
  - **너무 헐거우면** 이름까지 적어 둔 회귀를 못 잡는다. 같은 파일의 "첫 가로 휠"은 수정 전 **501ms**를 잡겠다면서 선이 1000이었다 — 그 회귀가 그대로 돌아와도 통과했다.
  - 실무 기준: **실측의 4~5배**, 그리고 **회귀 값 아래**. 둘이 겹치지 않으면(회귀가 실측의 5배 안쪽이면) 벽시계 대신 다른 판정자를 쓴다 — 호출 수·할당 수·복잡도처럼 기계 속도와 무관한 값이다.

  - **적용 사례(2026-09-01)**: 비동기 wake 적용 지연(`wake_apply_latency_budget_ns`)이 같은 함정에 빠져
    있었다. 선이 `60ms`인데 CI 정상값이 36~42ms라 **1.4배**였고, 러너가 붐비면 60.4·61.8·63.3·71.6ms가
    나와 **무관한 PR 다섯을 막았다**(2026-08-31). 로컬은 24.0~24.1ms로 흔들림이 0.1ms 안쪽이라 **코드가
    느린 것이 아니었다** — 선이 러너를 재고 있었다. 위 기준대로 CI 실측(42ms)의 4.8배인 `200ms`로 옮겼고,
    잡으려는 회귀(비동기 wake가 안 걸려 폴링으로 떨어지면 지연이 cadence 주기에 묶여 수백 ms)와 겹치지
    않아 벽시계가 여전히 유효한 판정자다.
## 현재 측정 명령

```sh
mise run perf
```

현재 산출물:

```text
tests/artifacts/perf/core.txt
```

CI에서는 이 파일을 `maru-performance-artifacts` artifact로 업로드한다. 숫자가 나빠졌을 때는 먼저 artifact를 보고 어떤 측정 항목이 느려졌는지 확인한 뒤, 관련 책임 경계의 trace/snapshot을 추가해 루트커즈를 좁힌다.

## CI 운영 모델

| 실행 경로 | PR 머지 차단 | 목적 |
| --- | --- | --- |
| `mise run perf` | 해당 없음 | 로컬에서 큰 구조 변경 전후를 직접 비교한다. |
| GitHub `Performance` PR check | 예(required) | 성능 회귀가 main에 들어가기 전에 잡는다. 트리거는 모든 PR에 열어 두고(workflow-level paths 필터를 두면 무관한 PR에서 required 체크가 영원히 pending으로 머지를 막는다) `code` 축이 바뀐 PR에서만 job-level 조건으로 실행한다([변경 영역별 실행](#변경-영역별-실행job-level-게이트)). |
| GitHub `Performance` 수동 실행 | 아니오 | 의심스러운 변경 후 같은 runner 환경에서 한 번 더 확인한다. |
| GitHub `Performance` `main` push | 아니오 | 머지 후 장기 추세를 확인한다. |
| GitHub `Performance` 주간 schedule | 아니오 | 조용히 쌓이는 성능 회귀를 정기적으로 발견한다. |

PR 경로의 성능 workflow 실패는 머지를 막는다. 예산은 runner 변동을 흡수할 만큼 여유 있게 잡으므로 실패는 대부분 구조 회귀다 — 실패 artifact와 변경 범위를 보고 루트커즈를 고치거나, 근거를 남기고 예산을 조정한다.

## 필수 CI 체크

**draft PR 에서는 실행 job 을 건너뛴다.** 초안을 올려 놓고 고치는 동안 macOS 러너 세 대가 매 푸시마다 도는 것은 낭비다. 가드는 job-level `if` 의 `github.event.pull_request.draft != true` 이고, 스킵된 job 은 conclusion=skipped 로 보고돼 branch protection 이 통과로 취급한다. 두 가지가 함께 필요하다.

- **`changes` 판정 job 은 가드에서 제외한다.** 그것까지 스킵하면 `needs.changes.result != 'success'` 가 되어 소비 job 들이 fail-safe 로 **오히려 다 돈다**.
- **트리거에 `ready_for_review` 를 넣는다.** 기본 types(opened·synchronize·reopened)에는 없어서, draft 를 푸는 순간 아무 이벤트도 오지 않아 건너뛴 job 이 영영 안 돈다.

`require label and assignee=ohah`(pr-metadata.yml)는 가드하지 않는다 — 가볍고, 라벨 누락을 초안 단계에서 미리 알려주는 편이 낫다.

`main` branch protection의 required status check는 이 절을 단일 출처로 둔다. 문서에 hard gate·"머지할 수 없다"로 적힌 검사는 이 목록에 있어야 하고, 목록과 실제 `required_status_checks.contexts`가 어긋나면 이 표를 기준으로 맞춘다.

| required 컨텍스트 | 생성 워크플로 · job | 실행 조건 |
| --- | --- | --- |
| `check` | ci.yml `check` | 매 PR(ubuntu). **항상 실행**하되 범위를 좁힌다 — `code`면 fmt-check·unit·e2e·oracle·stress·boundary·build, 문서 전용이면 `check-config-docs`만, web 전용이면 검사 없음. |
| `require label and assignee=ohah` | pr-metadata.yml `require-label-and-assignee` | 매 PR. 라벨 1개 이상 + assignee=ohah. |
| `core performance budget` | performance.yml `core-performance-budget` | `code` 변경 PR(+main push·수동·주간). core perf guardrail. |
| `file explorer macOS product path` | ci.yml `file-explorer-macos` | `code` 변경 PR(macos-15). 16,384-row/1,000-event 탐색기 artifact. |
| `session host macOS (Debug)` | ci.yml `session-host-macos-debug` | `code` 변경 PR(macos-15). `zig build test-session-host` — codec/state machine·live-upgrade fixture를 safety check가 켜진 채 검증. **job 상한은 35분**이다. 2026-08-31 PR #2938의 콜드 러너에서 출력된 모든 테스트가 통과한 뒤 기존 20분 상한에 도달해 `The operation was canceled`로 잘렸으므로, 성공 경로를 취소하지 않되 실제 hang도 유한하게 닫는 값으로 bundled CLI와 같은 35분을 쓴다. |
| `session host bundled CLI macOS` | ci.yml `session-host-bundled-cli-macos` | `code` 변경 PR(macos-15). ReleaseFast 앱 번들/PATH와 harness-owned localhost OpenSSH의 public `maru attach` 제품 E2E. Debug 전수 스위트와 병렬 실행하고 **각각 35분 상한**으로 독립 판정한다. |
| `session host slow observer macOS` | ci.yml `session-host-slow-observer-macos` | `code` 변경 PR(macos-15). 독립 ReleaseFast host의 실제 forkpty/3-client isolation·host-PID RSS와 generation-backed GUI client idle-pump artifact. |
| `web build and security fixtures` | web.yml `check` | `web` 변경 PR. web build·보안 fixture. |

**`session host macOS (ReleaseFast)`는 required가 아니고 자동으로 돌지 않는다.** 이 표에는 오래 required로 적혀 있었지만 실제 `required_status_checks.contexts`에는 없다 — 실행 시점을 PR에서 main push로 옮길 때 함께 뺀 것이 의도이고, 이 표가 그 결정을 따라오지 못했다(2026-08-17 정정). 같은 날 시점을 한 번 더 옮겨 **`workflow_dispatch` 수동 실행 전용**이 됐고, [릴리스 절차](distribution.md#ci-릴리스github-actions)가 태그 푸시 전 `gh workflow run ci.yml`로 이 잡을 돌릴 책임을 진다. **Debug와 중복이 아니다**: 같은 스위트를 도는 것은 맞지만 실행 체제가 다르다. ReleaseFast에서는 `std.debug.assert`(session host 소스에 123개)와 정수 오버플로·배열 경계·`unreachable` 런타임 검사가 모두 사라지고 최적화가 fork/exec·소켓·스레딩 인터리빙을 바꾼다. 출하 `.dmg`가 ReleaseFast이므로 이 잡만이 **출하 체제**를 검증한다. 그래서 없애지 않고 시점만 계속 뒤로 옮긴다. 대가는 그만큼 커진다 — **main이 초록이어도 릴리스 직전에 이 잡이 처음 빨개질 수 있다.** 얻는 것은 main push마다 macOS 러너 14분과 main 그룹 캐시 항목 하나(약 500MB × 최신 2개)다. 근거와 실측(잡 8개 합계 24분 46초 중 이 잡 8분 14초)은 `ci.yml`의 job 주석이 소유한다.

**Mermaid 제품 성능 게이트는 이 목록에서 뺐다(2026-08-17).** `mermaid macOS product path` job과 required 컨텍스트를 함께 제거했다. 근거는 회귀 압력이다 — Mermaid는 기능 추가를 멈춘 영역인데 그 job은 모든 `runtime`·`web` PR에서 macOS 러너 3분을 상시로 썼다. 병렬 배치라 wall-clock은 줄지 않고 러너 분만 줄어든다. **검증 수단은 남아 있다** — `mise run macos-mermaid-perf`는 그대로이고 [파일 패널 Markdown 읽기·소스 예산](#파일-패널-markdown-읽기소스-예산)의 Mermaid 행도 제품 계약으로 유효하다. Mermaid나 `web/dist/mermaid-helper.js` 경로를 다시 손댈 때는 로컬에서 이 게이트를 돌린다. 대가는 명시적이다: **다른 변경이 Mermaid tick 예산을 깨뜨려도 CI가 알려주지 않는다.** Mermaid에 기능을 다시 얹거나 네이티브 렌더로 옮기는 작업을 시작하면 job과 required 컨텍스트를 되살린다.

### 변경 영역별 실행(job-level 게이트)

문서 한 줄을 고친 PR에 macOS 러너 세 대와 외부 오라클을 태우지 않는다. 어떤 축을 실행할지는 **`tools/ci/changed-areas.sh`가 단일 출처**이고, 워크플로는 그 결과(`code`·`runtime`·`web`·`docs`)만 소비한다. 축은 서로 독립이다 — Zig만 바꾸면 `web:check`를 돌리지 않고, web만 바꾸면 Zig 게이트를 돌리지 않는다.

| 변경 경로 | `code` | `runtime` | `web` | `docs` |
| --- | --- | --- | --- | --- |
| `docs/configuration.md` | ✓ | ✓ | | |
| `docs/**`, `*.md`, `LICENSE`, `.claude/**` | | | | ✓ |
| `src/**`, `tests/**`, `tools/**`(ci 제외), `terminfo/**`, `assets/**`, `build.zig`, `build.zig.zon` | ✓ | 주석 전용이면 ✗ | | |
| `web/**` | | | ✓ | |
| `.mise.toml`, `.github/**`, `tools/ci/**` | ✓ | ✓ | ✓ | |
| 그 밖의 모든 경로(미분류) | ✓ | ✓ | ✓ | |

**`code`와 `runtime`을 나누는 이유.** 분류기는 확장자로만 영역을 가르므로 **주석 한 줄**만 고쳐도 `.zig`라는 이유로 macOS 러너 세 대가 돈다(실측 당시엔 다섯 대였다: 문서 분할 PR 여덟 건이 전부 그랬고, 그때마다 cold-render 플래키에 노출됐다). 주석은 런타임 동작을 바꾸지 않으므로 macOS·오라클·성능 job은 `runtime`을 본다. **`check`(ubuntu)는 계속 `code`를 본다** — `check-boundaries`의 external source digest가 doc comment(`///`·`//!`)를 잠가서, 주석만 고쳐도 digest가 움직이고 그 게이트를 건너뛰면 값이 깨진 채 머지된다.

주석 판정은 `*.zig`·`*.swift`·`*.m`·`*.h`에만 적용하고, 추가·삭제된 줄이 **전부 줄 시작 `//` 또는 빈 줄**일 때만 주석 전용으로 본다. 문자열 안의 `//`(`"https://…"`)는 줄 시작이 아니라 걸리지 않고, 한 줄이라도 코드가 섞이면 즉시 `runtime`을 켠다. `.mise.toml`·`.github/**`·`tools/ci/**`는 주석이 무해한지 겉으로 알 수 없어 판정 없이 항상 켠다.

**workflow-level `paths` 필터는 여전히 쓰지 않는다.** required 워크플로에 `paths`를 두면 무관한 PR에서 워크플로 자체가 트리거되지 않아 required 컨텍스트가 영원히 pending으로 머지를 막는다. 반면 job-level `if:`로 건너뛴 job은 GitHub이 `conclusion=skipped`로 **보고**하고 branch protection은 이를 통과로 취급한다. 그래서 `pull_request` 트리거는 모든 PR에 열어 두고 job 단위로 거른다.

**`docs/configuration.md`는 문서가 아니라 빌드 입력이다.** `build.zig`가 anonymous import로 등록하고 `src/config/schema.zig`가 `@embedFile("config_doc_md")`로 컴파일 타임에 박아, 키 표에서 행을 지우거나 range 숫자를 틀리게 적으면 `zig build test`의 doc-drift 테스트 두 개가 깨진다. 그래서 이 파일만 `code` 축이다 — 문서로 분류하면 그 두 테스트를 건너뛴다. 앞으로 문서를 빌드 입력으로 추가하면 이 표에도 함께 올린다.

diff를 읽을 때 두 가지를 강제한다. `--no-renames`는 rename 감지를 꺼서 원본 삭제와 대상 추가를 **둘 다** 보게 한다(감지가 켜지면 새 경로만 나와 `src/foo.zig` → `docs/foo.md` 이동이 "문서 전용"으로 오판된다). `core.quotePath=false`는 비ASCII 경로가 `"docs/\355\225\234.md"`로 이스케이프돼 앞의 따옴표가 경로 매칭을 깨뜨리는 것을 막는다.

판정이 없을 때 게이트가 조용히 열리면 안 되므로 모든 경로를 fail-safe로 잡는다. 분류기는 base/head가 없거나(push·schedule·수동) diff가 실패하면 전 영역 실행을 내보내고, 어느 패턴에도 안 걸린 새 경로도 전 영역으로 본다. 소비 job은 `needs.changes.result != 'success'`를 조건에 함께 넣어, `changes` job이 실패·오류로 끝나도 skip이 아니라 실행된다. `changes` 자체는 required 컨텍스트가 아니다. 분류기의 동작은 `mise run ci:changed-areas-check`(=`tools/ci/changed-areas.test.sh`)가 실제 git diff로 고정하며 매 PR의 `changes` job이 판정 전에 이 테스트를 먼저 돌린다.

이 목록을 바꿀 때는 `gh api repos/<owner>/<repo>/branches/main/protection/required_status_checks`의 `contexts`도 함께 갱신한다.

**조건부 job은 matrix로 두지 않는다.** matrix job이 job-level `if`로 skip되면 GitHub은 확장 **전** 이름(`session host macOS (${{ matrix.optimize }})`)으로 한 번만 보고한다. 조합별 required 컨텍스트는 그 run에 아예 나타나지 않으므로, 코드가 안 바뀐 PR이 두 컨텍스트 pending으로 영구 BLOCKED된다(2026-08-03 PR #1823에서 실측). 그래서 `session-host-macos-debug`·`session-host-macos-releasefast`는 `name:`을 리터럴로 고정한 **명시 job 두 개**다 — skip될 때도 그 이름 그대로 `conclusion=skipped`가 보고돼 branch protection이 통과로 본다. 조건 없이 항상 도는 job만 matrix를 써도 안전하다.

**job을 쪼개면 required 등록도 함께 늘린다.** 조합·job마다 독립 컨텍스트로 보고되므로 **전부** 등록해야 한다. 하나만 등록하면 나머지는 실패해도 머지를 막지 못한다. 반대로 job을 쪼개면서 required 등록을 빠뜨리면, 쪼개기 전에는 상위 job의 실패로 잡히던 게이트가 조용히 advisory로 강등된다.

## 현재 자동 예산

| 항목 | 현재 예산 | 측정 범위 | 이유 |
| --- | --- | --- | --- |
| `core_large_output` | 2,000ms 이하 | 100,000개 CRLF line을 `TerminalCore.write`에 입력 | 대량 stdout에서 무한 루프나 비정상적으로 느린 cell update를 조기에 찾는다. |
| `core_resize_loop` | 2,000ms 이하 | 5,000회 resize/write 반복 | window resize, font size 변경, split/workspace restore가 storage 불변식을 깨지 않는지 본다. (1s→2s 상향: CI runner 부하 변동이 1s를 간헐 초과 — 구조 회귀 2배+는 여전히 잡는다.) |
| `snapshot_serialize` | 1,000ms 이하 | 120x40 화면에 400행 출력 후 구조화 직렬화 200회 | 관측 가능성 도구가 너무 무거워져 hot path를 방해하지 않도록 감시한다. |
| `scrollback_rewrap` | 2,000ms 이하 | 스크롤백을 cap(1,000행)까지 채운 뒤 "resize + 스크롤" 50회(지연/앵커 재-wrap 교대) | resize 후 처음 과거를 보는 순간 1회 일어나는 재-wrap 비용이 조용히 커지지 않게 고정한다. |
| `core_find_scrollback` | 2,000ms 이하 | 5,000행 스크롤백(120열)에서 `findMatches` 20회(매치 1,111개) | 스크롤백 Find는 인덱스도 결과 캐시도 없이 검색어 키 입력마다·Find가 열린 채 출력이 있는 매 tick마다 core lock 아래에서 전체를 재스캔한다. 그 비용이 스크롤백 깊이에 **선형**으로 유지되는지 고정한다(측정상 증분 캐시 불필요 결론의 전제를 지킨다). |
| `kitty_image_pipeline` | 2,000ms 이하 | 최악 근사(200 placement × 50 image)로 `buildGpuImages`+`planImageUploads` 1,000회 | 이미지가 있는 동안 매 frame 도는 파이프라인 비용의 회귀를 잡는다(측정상 캐시화 불필요 결론의 전제를 지킨다). |
| `render_build_drawlist` | 2,000ms 이하 | 300×90 full-dirty·전 셀 장식 화면에서 `renderSnapshot`+`buildDrawList` 200회 | 렌더가 core_mutex를 잡은 채 dirty 셀을 복사하는 락-보유 구간의 상한 — 길어지면 I/O 스레드가 대기한다([io-render-threading.md §5](io-render-threading.md)). |
| `render_build_scrolled` | 2,000ms 이하 | 같은 화면을 과거 스크롤(view_offset>0) 상태로 200회 | 과거를 보는 중 매 frame 도는 viewport 합성+복사(둘 다 락 안)의 정상 상태 비용을 잰다. |
| `core_command_queue` | 2,000ms 이하 | enqueue→pop→free 라운드트립 100,000회 | 메인발 코어 mutate 위임(`CoreCommandQueue`)의 latency 바닥이 UI 이벤트 빈도에서 무시 가능하게 유지한다([plans/io-render-threading.md §9.7](plans/io-render-threading.md)). |

이 숫자는 최종 제품 목표가 아니다. 현재 core가 실수로 극단적으로 느려지는 것을 막는 최소 guardrail이다. 각 예산·반복 수의 상세 근거 주석은 `tools/perf/core.zig`를 단일 출처로 둔다.

## CR6e 영속 세션 호스트 reconnect 예산

이 예산은 hosted runner의 임의 숫자가 아니라 `Mac16,9`·Darwin `25.5.0`·16 logical CPU 전용 runner에서 ReleaseFast로 수집한 raw baseline에만 적용한다. 환경이 다르면 완화하거나 skip하지 않고 `EnvironmentMismatch`로 실패하며 재baseline PR이 이 표와 validator 상수를 함께 바꿔야 한다.

- transport baseline: 6 batch. hello stall p50/p95/max `252.12/252.17/252.17ms`, backoff `192.85/200.04/200.04ms`; resident delta max `245,760B`, footprint delta max `65,536B`, CPU delta max `58,273ns`, FD는 전부 `5→5`였다.
- actual-AppKit baseline: 5 batch의 각 iteration 0 warm-up을 제외한 20표본. launch→row p50/p95/max `451.59/499.40/559.95ms`, row→click `5.86/51.47/105.78ms`, click→visible `24.47/65.11/88.76ms`, visible→summary `92.53/173.35/183.16ms`, harness 전체 `717.54/967.11/1,074.19ms`; FD는 전부 `6→6`, 잔존 child는 전부 0이었다.
- 표본이 20개뿐인 AppKit 축에서 p99는 사실상 max와 같아 별도 통계인 척 쓰지 않는다. hard cap은 관측 max 위에서 runner 노이즈를 흡수하되, 2배급 구조 회귀 전에 닫히도록 정했다.

| 축 | hard cap |
| --- | --- |
| hello reply stall | typed `deadline_exceeded`, 1 attempt/0 wait, elapsed ≤260ms |
| transient backoff | typed `host_gone`, 10 attempt/9 wait, deadline 이내·elapsed ≤225ms |
| transport resource | FD delta 0, resident positive delta ≤512KiB, footprint positive delta ≤256KiB, CPU delta ≤2ms, peer/socket/manifest/host-dir residue 0 |
| AppKit launch→row | ≤750ms |
| AppKit row→click / click→visible | 각각 ≤250ms |
| AppKit visible→summary | ≤300ms |
| AppKit harness 전체 | ≤1,500ms |
| AppKit identity/cleanup | Swift-returned iteration exact match, before/after capture exact 1쌍, marker exact 1, runtime 생존, controller/observer 0, FD delta 0, child/socket/host artifact residue 0 |

`mise run session-host-cr6e-budget`은 한 pair를 판정한다. `mise run session-host-cr6e-soak`은 20 batch를 고정해 stalled transport 40행과 실제 AppKit recovery 100회를 실행하고 모든 raw pair를 마지막에 다시 전수 검증한다. 마지막 전수 판정도 a1/a2 standalone validator를 먼저 재사용해 canonical host identity, iteration 간 비중첩 시간 순서, deadline/cleanup 계약을 다시 확인한 뒤 hard cap을 적용한다. 이 gate는 로그인된 WindowServer가 필요한 opt-in 제품 검증이므로 기본 `mise run check`와 hosted CI에 넣지 않는다. 대신 validator의 strict schema·환경 drift·budget overshoot·고정 batch-count 테스트는 `check-boundaries`에 포함한다.

## CR6f 영속 세션 호스트 output wake 예산

`test-session-host-slow-observer-macos`의 실제 forkpty `/bin/cat` 제품 경로는 pressure workload 전에 별도 구분 가능한
marker 7개를 controller input으로 보내고 healthy observer의 valid screen delta에서 각각 관측될 때까지의 monotonic 시간을
raw artifact의 `wake_samples`에 전부 남긴다. 각 표본은 input 시작·socket 기록 완료·marker 적용 timestamp와 end-to-end·
delivery latency를 함께 가진다. `wake_latency_min_ns`·`wake_latency_median_ns`·`wake_latency_max_ns`는 validator가 raw
표본에서 다시 계산한다. marker 대기자는 healthy 제품 socket의 kernel readability를 blocking poll해 periodic test sleep의
runner overshoot를 제품 지연으로 귀속하지 않는다. marker가 들어온 batch를 적용한 뒤에는 측정 harness sleep 없이 같은 turn에서 timestamp를 찍고,
모든 observer의 wake delta를 비운 뒤 stall telemetry를 reset한다. 이 구간은 slow observer pressure와 RSS sampling 전에
측정해 stall 격리 비용을 입력 echo 예산으로 잘못 귀속하지 않는다.

output-wake 소유 구간은 `tools/perf/session_host_slow_observer_validator.zig`가 7표본 median **10ms**와 개별 tail **20ms**
hard cap을 소유한다. 기존 cadence-only 구조의 21~23ms floor는 두 gate에서 실패한다. wake 측정은 일반 80×24에서 수행한 뒤
slow-observer/RSS pressure 전에 512×256으로 resize한다. 대형 화면 projection을 wake 책임에 섞었던 격리 전 표본은 최대
99.9ms였지만, phase를 분리한 5회 연속 35표본은 median 2.8~3.1ms, 전체 max 5.2ms였다. validator는 7개 raw 표본의
개수·순서·exact subtraction·min/median/max 재계산과 median/tail cap+1 실패를 검증한다.
같은 artifact는 READY 뒤 controller·healthy·slow 세 stream을 모두 drain하면서 foreground refresh 500ms를 넘는 연속
600ms source-settle 창에서 observation materialization·core-lock·output-wake 증분 0을 먼저 확인한다. 최초 source 변경이
이 준비 창에 걸리면 그 뒤에서 bounded retry하며,
무변경 창을 한 번도 만들지 못하면 제품 idle 실패로 닫는다. 이 barrier 뒤 marker 전 1초 이상 idle 구간의
`RuntimeManager.OutputWakeEvidence` 전후값과
`proc_pid_rusage:RUSAGE_INFO_V4` user/system CPU 전후값도 남긴다. validator는 idle notify/write/coalesce/drain delta를 모두
0으로, user+system CPU delta를 **25ms 이하**로 판정한다. 이 상한은 1초 관측창에서 단일 core 2.5%이며 scheduler/계측
잡음에는 여유를 두면서 busy-spin이나 output-wake storm은 거부하는 값이다. active marker 구간은 notify delta 7 이상, 실제 write와 owner drain
delta 1 이상이어야 하므로 우연히 20ms cadence에 걸린 빠른 표본을 wake 성공으로 세지 않는다. 실제 pipe 포화 `EAGAIN`,
`EINTR` 분기, broken read-end `SIGPIPE`, drain 뒤 idle readiness와 restore graph의 새 process-local notifier는
`runtime_manager.zig` 단위/process 테스트가 별도로 소유한다. 이 숫자를 바꾸려면 같은 runner의 raw artifact와 validator
상수·이 절을 함께 갱신한다. 이 1초 제품 gate는 장시간 idle soak를 대체하지 않는다.

## P4 E2 runtime-shared observation cache 예산

`test-session-host-e2c`의 ReleaseFast 제품 fixture는 실제 `/bin/cat` runtime 1·10·100개에서 최초
materialization을 각각 정확히 1·10·100회, 같은 sweep의 둘째 consumer와 다음 idle cadence의 증분을 0회,
runtime 하나의 source generation 변경 뒤 증분을 정확히 1회로 판정한다. materialization마다 core lock 획득은
BEL·clipboard·screen의 정확히 3회여야 한다. 이 호출 수 판정은 하드웨어 속도와 무관하며 client 수나 idle cadence가
제품 작업량을 다시 늘리는 구조 회귀를 잡는다.

`session-host-slow-observer-macos.json` v3는 별도 ReleaseFast host의 실제 controller·slow observer·healthy
observer 제품 경로에서 누적 materialization, core-lock 획득 수, lock hold total/max와 1초 idle 전후 증분을
남긴다. validator는 누적 획득 수가 `materializations * 3`과 정확히 같은지, idle 구간의 materialization·lock
획득·lock hold 증분이 모두 0인지 판정한다. observation-owned heap copy·canonical JSON·cache transaction은
materialization 안에서만 열리므로 idle materialization 0이 이 경계의 allocation opportunity 0을 구조적으로
증명한다. 전체 프로세스 allocator 호출 수를 대신 주장하지 않는다.

개별 core-lock hold max hard cap은 **25ms**다. timestamp를 lock 획득 직후와 unlock 직전에 읽는 실제 hold 정의의
로컬 5회 실측 max는 0.209~0.375µs였다. 이 벽시계에는 lock을 쥔 host thread의 OS preemption도 포함되므로 통상값의
4~5배를 쓰면 구조가 아니라 scheduler를 판정한다. 호출 수·idle 증분이 일상적인 구조 회귀를 기계 독립적으로 잡고,
25ms는 lock 아래 blocking I/O나 장시간 작업 유입만 잡는 재앙 감지선이다. idle CPU **25ms**, healthy delivery median **10ms**/tail **20ms**, RSS analytic cap은
같은 artifact의 기존 CR6f·slow-observer 판정을 그대로 공유한다. lock cap, 구조 counter, raw RSS/CPU/latency 중
하나라도 없거나 불일치하면 exact-schema validator가 fail-closed한다.

## P4 E3 event-driven screen delta 예산

이 예산은 output self-pipe가 있다는 사실이나 wake latency만으로 screen producer가 event-driven이라고 과장하지 않는다.
실제 제품 `RuntimeManager.deltaOp`·snapshot projector 입구와 screen-owned allocator를 계측해, steady idle과 다른 runtime의
변경에서 호출되지 않았음을 구조 counter로 판정한다. 전체 프로세스 allocation 0은 주장하지 않는다.

| workload | hard gate |
| --- | --- |
| actual runtime 1·10·100, controller+observer attach 뒤 1초 steady idle | delta call=0, snapshot call=0, screen-owned allocation=0, screen core-lock acquisition=0; host user+system CPU delta ≤100ms |
| 100 runtime 중 한 runtime에 marker 7개 | 변경 runtime만 delta 후보가 되고 sibling runtime delta/snapshot=0; marker별 healthy delivery median ≤10ms·tail ≤20ms |
| hidden stream·slow observer·resync | hidden unchanged stream projector=0; slow observer는 기존 queue/RSS cap을 지키며 controller/healthy 진행을 막지 않음; resync는 target fresh snapshot exact 1, sibling projector=0 |
| change-token/lost-wake 경계 | checked overflow는 target fresh-snapshot recovery, stale/equal token은 publication 0; queue publish와 pipe drain이 교차해도 마지막 변경 token이 미관측으로 남지 않음 |

CPU 상한 100ms는 1초 창에서 single core 10%다. 현재 한 runtime idle 실측의 host 평균 78.34%와 `sample`의
`pollOnce -> collectOutputForLocalStreamAtEpoch -> deltaOp -> computeDeltaBounded` call graph를 RED baseline으로 보존한다.
구현 뒤 같은 격리 config와 `controller=yes` runtime evidence 없이 얻은 숫자는 비교에 쓰지 않는다. CI runner 차이 때문에
CPU만으로 구조를 판정하지 않고 exact-zero projector/allocation/core-lock counter를 함께 요구한다. E3b runtime metadata sampler는
같은 1·10·100 workload에서 unchanged runtime의 metadata producer visit·materialization·core lock·owned allocation 0을 추가로
요구한다. 한 runtime source change 뒤 sampler/materialization은 runtime당 exact 1이고 controller+observer delivery 수만큼
producer visit만 증가하되 sibling runtime visit은 0이어야 한다. output wake와 100ms deadline의 lost-wake interleaving,
slow observer/backpressure, revision exhaustion의 incarnation rollover에서도 target 외 visit·base mutation은 0이어야 한다. 이 구조
counter와 1·10·100 actual-runtime artifact gate가 함께 green이어야 P4 E3 전체를 완료 처리한다.

E3a 제품 배선 뒤 2026-08-28 동일 ReleaseFast artifact v3 실측은 1·10·100 runtime의 1초 창에서 CPU
0.025691ms·0.081410ms·1.162807ms였고, 세 행 모두 snapshot/delta/owned-allocation/core-lock 증분 0이었다.
같은 run의 healthy delivery median은 0.152750ms, max는 1.494833ms였다. 이 값은 상한을 완화하는 기준이 아니라
raw artifact가 실제 제품 경로를 통과했다는 기록이며 validator는 위 hard cap만 판정한다.

E3b 제품 배선 뒤 2026-08-28 ReleaseFast artifact v4 재실측은 1·10·100 runtime의 1초 창에서 CPU
0.087600ms·0.463486ms·5.099731ms였고, 세 행 모두 metadata producer visit/materialization/core-lock 증분 0을
screen projector 계열 exact-zero와 함께 기록했다. 100 runtime 중 한 target의 source 변경은 sampler 1회,
연결된 stream producer 3회, runtime-shared materialization 1회, stream별 core-lock 3회였으며 sampler failure는 0이었다.
이 수치는 환경별 성능 상한을 완화하지 않으며 exact-schema validator가 구조 counter와 함께 판정한다.

## P4 E3c client idle-pump 예산

이 예산은 위 E3a/E3b host PID 측정을 GUI client 비용으로 재해석하지 않는다. 별도 ReleaseFast client process가 실제 독립
host에 generation-backed `RemoteTermBackend` runtime 1·10·15·100개를 붙이고, initial screen/metadata 수렴 뒤 정확한 60회
frame turn을 실행한다. `proc_pid_rusage:RUSAGE_INFO_V4`의 client user/system CPU 전후값과 제품 경로 counter를 하나의
strict-schema artifact에 남긴다. `std.time.Timer` 벽시계만 재거나 legacy `RemoteRuntime` fixture, fake drain hook,
host PID CPU를 대신 쓰면 이 gate를 충족하지 않는다.

| workload | RED measurement gate |
| --- | --- |
| 1·10·15 runtime, 60 idle frames | frame=60; selected owner=`runtime_count * 60`; applied metadata/screen/ended=0; `pumpDelta`, timestamp seal, registry visit, socket read와 client CPU를 raw 기록 |
| 100 runtime, 60 idle frames | selected owner=`max_owners_per_frame * 60`; 모든 runtime이 round-robin에서 최소 한 번 선택; applied event=0; counter와 client CPU raw 기록 |
| 100 runtime 중 한 target marker | 왕복을 **40회** 재고 회차마다 target screen output event exact 1 이상, sibling output event=0. **성능 계약은 프레임 턴 수가 진다** — 마커를 보기까지 도는 턴의 p95 ≤ **6**(실측 p95 3·max 3, 잡으려는 회귀는 전달이 폴링으로 떨어져 턴이 수십으로 뛰는 것). 벽시계는 재앙 감지선으로 남겨 지연 p95 ≤ **200ms**·max ≤ **500ms**(실측 p95 27~43ms 의 4.6~7배 — 옛 60ms 는 실측의 1.4배라 [위 규율](#원칙)이 「감지선이 아니라 동전 던지기」라 부르는 상태였다) |
| cleanup | host/runtime/client child 전부 reap, fd/socket/directory residue 0, 계측 counter owner 해제 뒤 재사용 0 |
| AppKit native wake reconciliation | steady-state exact identity에서 새 Array/Set/String backing allocation 0; original borrowed fd read/close 0; source별 CLOEXEC duplicate를 cancel handler가 exact 1 close; identity 변경 시 old source cancel exact 1; actual handler 진입→Metal frame 뒤 screen probe 관측 ≤60ms(반복 raw 표본 기록) |

첫 슬라이스의 CPU 값은 hard cap을 정하기 위한 진단 baseline이었다. 구조 수정 전 RED와 수정 후 표본을 얻은 뒤 아래처럼
25ms hard cap과 registry/socket exact-zero를 확정했다. timestamp seal과 registry visit은 실제 발생 횟수 그대로 각각 기록해야
하며, 둘 중 하나를 다른 값으로 추정하거나 합산해서는 안 된다. 최적화 완료 판정은 idle에서 불필요한 authority/transport
작업이 구조적으로 0이고, active marker latency가 후퇴하지 않으며 위 cleanup이 모두 성립할 때만 가능하다.

2026-08-28 첫 ReleaseFast RED는 1·10·15·100 runtime에서 각각 client CPU 0.552ms·2.238ms·4.926ms·3.915ms,
selected/pump/seal 60·600·900·960, registry visit 0, idle socket read 0을 기록했다. 15-runtime CPU는 단일 코어 환산
약 0.31%라 “4,096 registry scan이 유휴 부하의 지배 원인”이라는 가설을 기각한다. 반면 100-runtime target marker
33.810ms를 처음에는 기존 20ms tail 실패로 판정했지만, 적대적 재검토에서 그 20ms는 host의
`input_accepted_at_ns→marker_at_ns` delivery 구간이고 E3c 값은 GUI 입력부터 client screen apply까지라 종점이 다름을 확인했다.
같은 숫자를 재사용한 것은 scope 오류였다. E3c는 host acceptance 이전의 GUI enqueue turn과 host tail 20ms, 이후 GUI apply
turn 및 dispatch를 모두 포함하므로 합성 tail을 60ms로 둔다. 강화된 60Hz·실제 fd-cleanup 계측에서 probe/local-work priority 뒤 2 frame, timer timeout 1회,
max frame 8.745ms, end-to-end 30.557ms를 기록했다. 수정 gate는 60Hz·16-owner cap을 그대로 두고 probe 뒤 canonical queue와
로컬 pending input에 준비된 target을 같은 frame에 우선하며, quiet round-robin의 bounded 진행과 exact counter를 함께 보존해야
한다. 10Hz cadence 하향은 이 latency를 악화시키므로 채택하지 않는다.

각 60-frame idle 표본은 wall 0.9~10.0초 안에서 끝나고 client user+system CPU 25ms 이하, `ClientSlot` registry
visit exact 0, socket read attempt exact 0이어야 한다. `usleep`은 하한이라 macos-15 shared runner가 60회 nominal
16.7ms wait를 4.91~5.55초로 늘린 실측을 허용하되, 10초는 harness liveness 상한으로 남긴다. 실제 work 예산은
wall time과 분리된 raw process CPU 25ms다. 이 값은 첫 RED 최대 4.926ms의 약 5배로 runner noise를 허용하면서
nominal 1초 창에서 한 코어 2.5%를 넘는 idle 회귀를 닫는다. registry/socket 값은 단순 관측 필드가 아니라 최초
실측이 기각한 원인의 재도입을 막는 hard gate다.

실제 AppKit CR6e-a2 v2 반복 artifact는 ReleaseFast 앱 5회 모두 attach 뒤 handshake 출력에서 native handler exact 증가를
관측했고, handler 진입부터 normal tick의 Metal frame 뒤 screen probe까지 15.528·23.325·23.954·24.151·24.627ms였다.
다섯 행 모두 60ms 안이며 fd 6→6, child 0, daemon/socket/host artifact cleanup을 함께 통과했다. 이 하위 값은 host가
marker를 쓰기 시작한 시각을 포함하지 않으므로 전체 end-to-end latency라고 부르지 않는다.

## executeScript 16 MiB 구현 gate와 대용량 후속 연구

[control-plane-protocol.md §4.4](control-plane-protocol.md)가 구현 상태와 채택 계약의 단일 출처다. 5f-5c에서 strict-CSP `callAsyncJavaScript` expression+args+await, raw strict-JSON ≤512 KiB inline, 그 초과~16 MiB progressive JSON-RPC chunk, screenshot 공통 pump, connection 4 MiB/process 32 MiB queued+writer-owned 회계, Swift `Data` pin/pull/release와 CLI atomic spool이 live가 됐다. correctness와 실제 WKWebView pump p95/max는 자동 gate지만 RSS·bridge/frame 귀속은 아래 Track 5 성능 gate에 남아 있으므로 hello 16 MiB capability는 아직 광고하지 않는다.

| 항목 | Track 5 16 MiB 완료 예산 | 실패 시 |
| --- | --- | --- |
| main tick pump | pump 기여 p95 ≤ 0.5ms, max ≤ 1.0ms, pump 귀속 120Hz frame deadline miss 0 | chunk 축소 또는 base64/frame 준비를 off-main으로 이동 |
| WebKit result bridge | completion callback→worker handoff max ≤ 1.0ms, executeScript 전체 귀속 120Hz frame deadline miss 0 | WK IPC/Swift String materialization 포함 bridge 방식 재설계; 16 MiB 경로 비활성 |
| result 예약 | 개별 요청 ≤ 16 MiB, process-global aggregate reserved result bytes ≤ 256 MiB | 초과 요청은 실행 전 `resource-busy`; release 확인 실패는 예약 tombstone을 유지해 재사용 금지 |
| outbound queue | 연결당 queued+writer-owned wire hard cap ≤ 4 MiB, process-global hard cap ≤ 32 MiB; 그 안에 terminal carve-out 연결별 2 frame/64 KiB·전역 1 MiB; general pool의 75%에서 pump stop·50% 아래 resume | hard cap/회계 위반 또는 partial writer 뒤 terminal 혼합이면 연결 abort 후 기능 비활성 |
| host RSS delta | transient peak ≤ `2 × actual_bytes + 64 MiB`, pin 이후 steady ≤ `actual_bytes + 64 MiB` | full-size host copy를 줄이기 전 16 MiB 경로 비활성 |
| app+WebContent RSS delta | peak ≤ `4 × actual_bytes + 128 MiB` | page preflight/bridge 방식 재설계; 16 MiB 경로 비활성 |
| 수명·복사 | Zig/CLI에 full-size in-memory copy 0, backend terminal/final별 reservation/Data release 정확히 1회, abandoned pre-pin 실행은 backend terminal 전 조기 반환 0, WebContent crash 0 | execution/transfer registry/cancel/file sink 수정 전 비활성 |

RSS는 Maru 앱 프로세스와 해당 WebContent process를 분리해서 재고 combined도 함께 남긴다. 16 MiB fixture는 큰 string 하나만 쓰지 않고 flat array와 nested object를 포함하며 cap+1 bounded failure도 실제 WKWebView에서 잰다. callback 내부 시간만으로는 callback 전에 생기는 IPC materialization stall을 놓치므로 operation 구간의 frame tick gap도 함께 귀속한다.

## 파일 트리 FP7 예산

- render tick의 파일시스템 호출(`open`/`stat`/`readdir`) = **0**. tick은 background 완료 queue drain, L2 snapshot 교체, row projection만 한다.
- background directory scan 동시 실행 ≤ 4, 고정 완료 queue ≤ 16, scan request queue ≤ 1,024. directory child ≤ 4,096, 전체 materialized node ≤ 16,384, root ≤ 256, recent ≤ 32. backend retirement는 main actor에서 worker 완료를 기다리지 않는다.
- FSEvents latency/debounce = 200ms. 세부 scan queue overflow와 native dropped/must-scan/root-change flag는 event를 조용히 잃지 않고 root 전체 rescan으로 coalesce하며 stream 재구성은 마지막 event ID를 이어받는다.
- 결정적 gate는 L2 bounds/natural-sort/lazy subtree 보존, L4 tmpDir exclusion/symlink/root 탐색, clean reload/dirty conflict 통합 테스트다. GUI wall-clock/FSEvents delivery latency artifact는 수치 예산이 아직 없으므로 후속 macOS smoke에서 event→snapshot p95와 tick queue-drain 시간을 추가한다.
- 파일 생성·rename backend는 request queue 64, in-flight 1, completion queue 16으로 제한한다. macOS 휴지통 adapter는 queue 16, in-flight 1이다. cap+1은 명시적으로 거부하고 pending/capacity를 같은 tick에 회수한다. user mutation은 coalesce하지 않으며 동시에 대기 중인 watcher/coarse rescan만 `{root, deepest expanded ancestor}`로 합친다. staging/completion/recycle의 지연 FSEvents가 이미 완료된 scan 뒤 도착하면 현재 엄격한 scan 횟수 상한은 없으며, quiet-window scheduler가 후속 성능 gate다. frame tick은 FS I/O를 수행하지 않고 completion을 최대 1개만 처리하지만, 현 `pump()`는 요청마다 `Job` allocation과 detached thread spawn을 frame/main-actor 경로에서 수행한다. persistent worker 전환 전에는 tick allocation/thread-spawn 0을 주장하지 않는다. `NSWorkspace.recycle` callback 미도착은 결과가 불명확하므로 자동 retry/unlock하지 않고 bounded queue와 exit gate를 fail-closed로 유지한다.
- mutation completion은 worker가 검증한 kind·project root·path metadata와 필요한 snapshot을 소유한다. tick은 동기 `openFilePanelPath`/`rebuildFileTreeFromDock`를 재사용하지 않고 메모리 apply만 하므로 생성 자동 열기·directory rename을 포함해 `open/stat/readdir` 0이다. Trash 성공 뒤 dock bulk-remove는 최대 256 entry를 한 번 방문하고 dirty-sync/unlock/reload fixed queue를 각각 한 번 compact한 뒤 최대 64 empty leaf를 한 번 정규화한다. 이 모델·queue 구간은 allocator call 0이며, 제거 surface마다 호출하는 기존 native `surface_closed_callback`은 active browser control 응답을 `server.cross_gpa`에 직렬화할 수 있어 별도 **최대 제거 surface 수 256회의 bounded control-completion allocation**으로 귀속한다. 따라서 Trash completion 전체 allocation 0은 주장하지 않으며, callback을 worker로 옮기거나 fixed response pool을 도입하기 전에는 model gate와 native control 응답 예산을 합치지 않는다. submit 실패·worker 실패·completion/adaptor queue overflow 뒤에도 pending을 해제하고 notice+재시도가 가능해야 한다.
- rename admission은 `PathRemapPlan` 구성보다 먼저 처리해 queue-full cap+1의 plan allocation은 0이다. main actor는 최대 entry 256+recent 32의 영향 경로를 한 contiguous snapshot으로 복사하고, descendant join과 새 path allocation은 worker가 수행한다. perf artifact는 256-entry parent rename의 main-actor allocation count(1), copied bytes, submit 시간을 남긴다.
- keyboard navigation은 현재 materialized row projection만 순회한다. 키 입력 한 번의 비용은 row 상한 16,384 안에서 bounded이고 FS I/O·worker wait·WKWebView 생성은 0이다. directory rename으로 여러 pin path가 바뀌면 비활성 WKWebView는 lazy 재생성하고 보이는 view recreate queue(상한 8)는 tick당 1개만 drain한다. 같은 surface generation은 정확히 한 번만 재생성하며 실제 macOS smoke가 8-view parent rename의 frame gap과 app-host RSS delta를 artifact로 남긴다.

## 파일 도크 FP9 drag·focus overlay 예산

> **상태(2026-07-28)**: FP9 도크 드래그는 [file-panel.md](file-panel.md) §1에서 **폐기**됐다(FP16이 terminal 탭 드래그로 흡수). 그 기계는 이미 제거됐고, 마지막 잔재였던 floating title 빌더(`coretext_frame_builder.buildFloatingTabTitleDrawList`)도 호출자 없이 남아 있다 지웠다. 아래 표는 **FP9 당시 계약의 기록**이며 지금 자동 검증되는 gate가 아니다 — terminal 탭 드래그의 예산은 이 표가 아니라 그 경로의 문서를 따른다.

이 절은 [파일 패널 FP9](file-panel-dock-ui.md#33-파일-탭-드래그도크-내부-분할)의 drag hot path 수치와 실패 조건의 단일 출처다. FP9 구현은 동일 상수와 64-group/256-entry fixture를 소비하는 1,000회 perf artifact로 이 gate를 자동 검증한다.

| 경로 | hard gate | 실패 조건·구현 제약 |
| --- | --- | --- |
| pointer move | layout snapshot build ≤ 1, leaf visit ≤ 64, entry visit ≤ 256, allocator call = 0, lock acquisition = 0, FS I/O = 0, worker/thread hop = 0 | `groupCount()+groupAt(index)` 중첩 순회나 target별 layout 재계산, path/title 복사, 새 draw-list allocation이 한 번이라도 발생하면 실패한다. |
| projected frame | layout snapshot build = 0, allocator call = 0, lock acquisition = 0, FS I/O = 0, worker/thread hop = 0 | render/preview/hit-test는 pointer event가 만든 같은 snapshot을 읽고 frame tick에서 재구성하지 않는다. |
| drag/focus overlay | pointer move와 일반 projected frame에서 FP9 귀속 CoreText shape/raster call = 0. drop zone은 quad ≤ 1, focus inside border는 quad ≤ 4, floating tab box는 quad ≤ 5와 drag 시작 때 한 번 캐시한 title glyph quad ≤ 24 | title은 drag 시작 또는 실제 제목 변경 때만 shape/cache한다. pointer move는 캐시된 glyph/box의 placement만 바꾼다. perimeter 길이에 비례한 cell 생성이나 매-frame title shaping/raster가 발생하면 실패한다. drag+focus 동시 최악의 FP9 geometry quad는 ≤ 10이다. |
| workspace focus boundary 보정 | 기존 pane-chrome leaf 순회에 active geometry capture를 융합하고 별도 layout entrypoint·leaf-search loop는 source/call-boundary audit에서 0이어야 한다. `workspace.max_panes_per_tab`×1,000 projection seam의 allocator call = 0, border quad = 4, overlay presence sentinel = 1, focus 왕복의 WebView transition = 0 | frame build가 active leaf에서 `PaneGeometry.body`와 `.grid`를 함께 얻어야 한다. border target을 찾으려고 `activeTabLeafRects`를 다시 호출하거나 별도 body cache/invalidation을 추가하면 실패한다. 현재 자동 artifact는 synthetic cap projection의 allocation 0과 production caller의 loop 융합을 검증하며, production tick 변경 전/후 layout-build·leaf-visit counter 자체는 아직 계측하지 않으므로 그 delta를 자동 증명한다고 주장하지 않는다. |
| surface transition | preview는 create/destroy/reframe/show/hide = 0. live-surface commit은 create/destroy = 0이며 §3.3의 bounded reframe/show/hide를 지킨다. surface-less commit은 lazy create ≤ 1, destroy = 0이다. | live와 surface-less artifact를 분리한다. lazy create 실패는 workspace focus와 재시도 가능 entry를 유지해야 하며 transition 상한을 맞추려고 표시를 억제하면 실패한다. |

계측은 1,000회 pointer move와 projected frame을 반복해 누적값과 event/frame별 최댓값을 함께 남긴다. cap+1 admission은 split/group allocation 0과 다음 layout frame allocation 0도 단언한다.

## 에이전트 세션 기록 도크 예산

이 절은 [에이전트 세션 기록 도크](agent-session-list.md) AS2/AS3의 hot path 계약을 소유한다. provider JSONL은 민감하고 대형일 수 있으므로, 빠른 첫 목록과 main-thread 격리를 같은 gate로 다룬다.

| 경로 | hard gate | 실패 조건·구현 제약 |
| --- | --- | --- |
| 탭 재진입·기존 snapshot | 15초 TTL hit: filesystem I/O = 0, JSON parse = 0, worker wait = 0 | 앱 실행 중 snapshot이 있으면 즉시 그것을 렌더한다. TTL hit는 refresh도 시작하지 않으며, force refresh만 이를 우회한다. cache miss가 pointer/key/frame 경로에서 동기 scan을 시작하면 실패한다. |
| worker first batch | candidate metadata만으로 newest-first, parse concurrency ≤ 4, batch ≤ 50 | 파일 내용 전체를 먼저 읽어 정렬하거나, 500개 완료를 기다려 첫 결과를 publish하면 실패한다. 최초 batch wall-clock은 macOS fixture에서 별도 artifact로 관측하며, 개인 history를 artifact에 넣지 않는다. |
| refresh parse | file ≤ 128 MiB, refresh read ≤ 512 MiB, unchanged identity cache hit read = 0 | `(device,inode,mtime,size)`가 같은 파일은 이번 앱 실행에서 재parse하지 않는다. stale identity·cap·cancel은 partial로 표시하며 cache가 오래된 record를 현재 결과로 위장하면 실패한다. |
| frame tick·검색·행 선택 | filesystem I/O = 0, JSON parse = 0, worker wait = 0 | tick은 immutable batch queue drain과 snapshot 교체만 한다. 검색/선택은 published snapshot만 소비하며 scan·provider 실행을 요청하지 않는다. |
| scope 선택·현재 프로젝트 root | main actor filesystem I/O = 0, JSON parse = 0, worker wait = 0 | 작업공간은 이미 검증된 explorer root snapshot만 복사한다. 현재 프로젝트는 활성 Term의 in-memory cwd만 capture해 별도 worker가 canonicalize·`.git` ancestor walk를 수행하고, 결과가 돌아오기 전에는 `프로젝트 분석 중`으로 표시한다. |
| 도크 텍스트 셰이핑(cache miss frame) | run마다 face를 다시 만들지 않는다: 셰이핑 run 수만큼 **캐시 hit, miss = 0**. 용량을 넘긴 뒤에도 같다(축출이 있어야 성립) | 도크 텍스트는 cache miss frame에서 render tick 안 **동기**로 셰이핑한다([agent-session-list.md](agent-session-list.md) §4). 그 비용이 예산 안에 있는 근거가 native bridge의 face 재사용이다. 게이트는 **재사용 횟수를 직접 센다**(`maru_macos_coretext_chrome_font_cache_stats_for_test`) — 시간은 "실제로 제품 경로가 돌았다"는 최소 증거로만 쓰고 판정에 넣지 않는다(`chrome text shaping reuses one face across roles…`). 참고 실측(ReleaseFast, Apple Silicon): 55 run·969 glyph 한 frame이 재사용 전 6.25ms, 후 **1.43ms**. |

> **이 게이트는 원래 wall-clock 비율이었다**(같은 role 프레임 대비 섞인 프레임이 2배 이하). *"같은 머신에서 잰 두 측정의 비율이라 러너 부하에 흔들리지 않는다"*고 적었는데 **그 문장이 실측으로 반증됐다** — 부하가 있는 개발 머신에서 별도 worktree A/B를 12회 돌렸더니 **변경이 없는 기준선이 6회 중 5회 빨간불**이었고 관측 ratio가 2.44~3.11로 흩어졌다(2026-08-22). 두 측정 사이에 다른 일이 끼면 부하가 둘에 균등하게 실리지 않는다. 그리고 캐시가 **가득 차 막힌** 경우는 두 측정이 함께 느려져 비율이 그대로라 애초에 못 잡았다.
>
> **교훈은 "비율이면 안전하다"가 아니라 "셀 수 있으면 시간을 재지 마라"다**(2026-08-21, `807d7888`). 여기서 알고 싶었던 것은 *얼마나 빠른가*가 아니라 *face를 다시 만들었는가*였고, 그것은 카운터로 정확히 세진다. 시간으로 재던 동안 게이트는 구조 회귀와 스케줄러 노이즈를 구분하지 못했다.

## 파일 탐색기 scrollbar/icon 예산

이 절은 [파일 탐색기 §3](file-explorer.md#3-렌더--스크롤바아이콘)의 hot path를 소유한다. `app_session.zig`의 제품 glue를 직접 호출하는 macOS 테스트가 16,384 materialized row와 1,000회 pointer/frame을 실행하고 `tests/artifacts/perf/file-explorer.txt`에 실제 증가 지점이 있는 구조 counter만 남긴다. warm capacity 뒤 `FailingAllocator`의 실제 allocation 횟수와 기존 `dock_layout_build_count` delta를 함께 단언한다. 숫자 0으로만 초기화되는 가짜 lock/FS·MIME/worker/CoreText counter는 두지 않는다. 이 부재 계약은 filesystem/MIME API를 import하지 않는 중립 classifier/geometry 모듈 경계와 코드 검토가 맡으며, artifact가 자동 증명한다고 주장하지 않는다.

| 경로 | hard gate | 실패 조건·구현 제약 |
| --- | --- | --- |
| row projection icon classify | row visit ≤ 16,384, row당 classify ≤ 1, allocator call = 0 | basename/extension ASCII 비교만 허용한다. render/pointer event에서 재분류하거나 filesystem metadata·MIME database를 조회하면 실패한다. filesystem/MIME import 부재는 중립 모듈 boundary review가 맡는다. |
| scrollbar pointer move/drag | geometry build ≤ 1, allocator call = 0 | 저장된 total/visible/effective-scroll과 drag snapshot만 소비한다. divider/tab gesture owner 전환, generation 변경 뒤 commit, 매 move row scan은 실패한다. lock/I/O/worker 부재는 AppSession entrypoint review 항목이며 artifact counter로 과장하지 않는다. | **FP16(2026-07-28)**: 파일 콘텐츠를 담던 도크 editor가 제거되며 `dock layout rebuild = 0` 항목을 **폐기**했다 — rebuild를 세던 `dock_layout_build_count`·`invalidateDockTabSnapshot`과 그 대상인 file editor chrome이 삭제돼 측정 대상이 없다. AI 세션 기록의 scan/render 예산은 [agent-session-list.md](agent-session-list.md)의 AS2/AS3 gate가 추가로 소유한다.
| projected scrollbar update | classifier call = 0, scrollbar geometry build ≤ 1, allocator call = 0 | row에 저장된 semantic kind와 coverage PUA를 사용한다. thumb는 native quad≤1이고, icon cell은 draw-list 자동 테스트에서 visible row당≤1이다. fade는 L2 row projection/classifier를 재실행하지 않는다. 일반 text/icon shaping 전체의 0회는 주장하지 않는다. |

PR 2 검증은 branch protection에 이미 등록된 Ubuntu `mise run check`/`mise run perf`와 별도 macOS PR job의 전용 `mise run macos-file-explorer-perf`를 함께 실행한다. AppSession 제품-path test는 Ubuntu에서 skip되므로 macOS job만 artifact를 생성·업로드하며 누락은 그 job을 실패시킨다. 이 macOS job(`file explorer macOS product path`)은 branch protection required status다([필수 CI 체크](#필수-ci-체크) 참조). 실제 계측하는 zero/bounded counter 하나라도 어기거나 artifact가 없으면 시간과 무관하게 실패한다.

## 파일 패널 Markdown 읽기·소스 예산

| 경로 | hard gate | 실패 조건·구현 제약 |
| --- | --- | --- |
| CM6 input/IME transaction | unified/Mermaid 실행 0, iframe create/destroy 0, native bridge write 0, full-document `Text.toString()` 0, document-size 비례 copied bytes/allocation 0 | dirty는 CM6 `Text.eq`/revision으로 판정한다. composition 중 selection 재작성을 금지한다. |
| Mermaid 렌더 | Mermaid source≤32 KiB·Web 줄 개수≤512(`maxMermaidSourceLines`)·Zig 한 줄 바이트≤512(`max_line_bytes`), helper app-global in-flight≤1·pending jobs≤32·pending source≤1 MiB·exact terminal≤98·SVG≤512 KiB/job·accepted 합계≤2 MiB·cold response deadline≤5s·warm≤2s·60초 실패≤3 | Mermaid는 번들된 별도 `maru-mermaid-renderer` process에서만 실행한다. terminal queue는 backlog와 모든 pending/in-flight/accepted live job을 동시에 담는 98개 fixed storage이고 admission은 `terminal+live+growth` cap+1을 source copy와 기존 pending mutation 0으로 거부한다. coalesce·deadline·transient·integrity·invalid result·accepted capacity·failure latch는 모두 exact terminal을 내보낸다. frame tick은 terminal+accepted completion 합계≤8이다. timeout/crash는 helper를 terminate/restart하고 CM6·후속 job을 보존한다. navigation/widget revoke는 실행 중 결과만 stale 폐기해 helper를 재사용하며 100회 연속 in-flight 편집 revoke에서도 helper start=1·마지막 결과 수락=1이어야 한다. revoked hang은 해당 action의 cold/warm deadline과 failure budget으로 종료한다. 60초 안 3회 실패면 앱 수명 동안 disabled latch로 helper churn을 멈춘다. `MermaidJobCapability`가 late/duplicate result의 DOM mutation을 0으로 만든다. WebKit service CPU의 정확한 deadline 정지는 주장하지 않는다. |
| renderer capability | shell DOM에 Markdown 파생 HTML/SVG insertion 0, renderer bridge/message handler/asset/link action 0, Mermaid external request 0 | sanitize 성공만으로 shell insertion을 허용하지 않고 load-scoped MessagePort와 `RendererCapability { editor_epoch, document_revision, projection_generation, widget_id, widget_generation, renderer_instance }` 6-field 공용 alias를 모두 검증한다. |
| native frame tick | 파일 패널 귀속 FS I/O 0, WebView create/destroy 0, worker wait 0 | tick은 mode/action scalar와 기존 surface layout만 소비한다. 저장 FS I/O는 명시적 bridge command 경로다. |
| file/readAsset bridge | file·asset 각각 ≤ 8 MiB, viewer asset≤64·base64 합계≤48 MiB, frame/input tick 귀속 0 | 현 session bridge의 size-query/fill은 MainActor에서 정상 2회, size race retry 시 최대 4회 처리한다. `file.read`는 전체 read·UTF-8 검증·hash·JSON 직렬화를, `file.readAsset`은 전체 read·base64·JSON 직렬화를 반복한다. 이는 기존 ABI 형태를 따르는 bounded 명시적 open/reload·asset load 경로이며 frame tick 예산 통과 근거로 사용하지 않는다. request/epoch-scoped cached reply 또는 off-main ownership을 구현하고 8 MiB document 및 64-asset fixture의 wall-time·peak allocation artifact를 얻기 전에는 initial-open·asset-heavy latency budget을 통과했다고 주장하지 않는다. |

### 16 MiB 초과 후속 연구 gate

**PID 귀속 조사 결론(2026-07-14)**: public `libproc`의 PID identity/RSS 읽기 자체는 가능했다. 반면 공개 WebKit API는 WKWebView별 WebContent PID를 주지 않고, 조사에 사용한 `launchctl print pid/<pid>`의 resource coalition은 출력 포맷이 안정 API가 아니며 여러 webview/workspace/window churn에서도 후보 집합이 실행 중 바뀌었다. 따라서 coalition 후보 합은 후보 완전성이나 특정 WKWebView 귀속을 증명하지 못하고, 위 `app+WebContent RSS delta`의 실패 gate로 승격하지 않는다. 조사용 POC 코드와 test-only 훅은 결론을 얻은 뒤 제거했으며 제품/CI 계약으로 남기지 않는다. 정식 Track 5는 private WebKit PID API나 불안정한 `launchctl` 파싱을 채택하지 않고, 공개·안정된 귀속 수단이 생기기 전에는 app-host RSS만으로 combined 예산을 통과했다고 간주하거나 hello 16 MiB capability를 열지 않는다.

정상 workload의 12/16 MiB 초과 또는 base64/copy 병목이 §4.4 trigger를 만족한 경우에만 64/128/256 MiB를 순서대로 연구한다. 현재 parser와 hello는 이 tier를 허용하지 않으므로 stress 하니스는 production capability를 조용히 변경하지 않고 **test-only effective-max override**를 명시해야 한다. 각 tier와 cap+1을 실제 WKWebView에서 실행해 위 표의 tick·queue·RSS·lifecycle 예산을 그대로 적용하고, reserved 256 MiB ceiling을 실제 parser/admission에 연결한다면 hard-ceiling unit도 함께 추가한다. 연구 통과는 상한 확대나 binary/fd attachment의 자동 채택이 아니며 별도 설계 결정이 필요하다.

## Session-host event settlement·close maintenance 예산

[영속 터미널 세션 호스트](persistent-session-host.md)의 C3-3b owner 계약을 수치화한다. correctness gate는 러너 부하에 흔들리는
절대 시간 대신 실제로 읽은 byte·시도한 owner·allocation 수를 판정하고, ReleaseFast wall-clock은 ns/byte artifact로만 기록한다.

| 경로 | hard gate | 실패 조건·구현 제약 |
| --- | --- | --- |
| b2b1 trusted seal primitive | heap allocation = 0, fixed-shape aggregate input, 32-byte transcript/progress result | named `preparation`·`committed_observation` graph만 service 내부 fixed-order LE encoding으로 hash한다. transcript/progress/observation aggregate input의 slice와 caller-chosen count, generic writer·generic MAC·permit registry는 0이다. closed-role synchronous string content helper만 borrowed slice를 허용하며 저장·반환·allocation은 0이고 every-field/domain/role/order 변화가 seal을 바꾼다. |
| b2b2 recipe builder + caller-provided fill | heap allocation = 0, pointer/slice/allocator/owned storage = 0 | `EventPreparationRecipe`는 fixed scalar·length·presence·digest와 checked size arithmetic만 가진다. metadata payload span은 한 호출 안에서만 쓰며 recipe나 pending owner에 저장하지 않는다. |
| b2b2 compatibility owning wrapper | 기존 metadata 경로의 0/1 allocation exact-count 보존 | wrapper만 exact backing을 할당한 뒤 같은 fill을 호출하고 기존 DTO semantic/error/OOM 결과를 보존한다. |
| b2b3 `PendingEventOwner` prepare peak | owner당 variable backing checked sum ≤ `4 * protocol.max_control_json` | event payload·owned DTO·next observation·old observation의 actual capacity를 각각 control-frame cap 안에서 센다. 공용 `RuntimeObservation.replace`는 모든 owned slice를 exact-capacity로 만들고 staged entry는 old cache의 `capacity == len`을 요구한다. scalar/fixed array는 `@sizeOf` compile-time 상한으로 별도 계상한다. cap 초과는 pending publication과 live semantic mutation 0의 `ResourceExhausted`다. |
| `SettlementWorkBudget` frame | published rehash bytes ≤ `16 * 3 * protocol.max_control_json`, attempted owner ≤ 16 | b2b prepare peak의 payload·DTO·next·old 4-part budget과 구분한다. b3는 같은 owner의 settlement `Busy` 3회 exact-count만 소유하고, b4의 backend-global round-robin이 payload·next·old 3-part published rehash를 owner 최대 16개까지 수행한다. 다음 owner가 남은 byte budget을 넘으면 그 owner를 다음 tick 시작점으로 보존한다. owner hard cap이 frame cap보다 작아 다음 tick admission이 보장된다. budget 미획득 owner는 bytes read/hash/allocation 0의 `event_pending`이다. 0/1/16/17·최대 Runtime fixture가 exact byte/attempt와 eventual visit를 검증한다. |
| `CloseAuthority` maintenance | backend-global runtime ≤ 4,096, map visit ≤ 4,096, authority advance ≤ 16, selection compare ≤ `visited * 16`, scratch ≤ 256 KiB, heap allocation = 0 | current/N-1 multi-host 합산 cap/cap+1을 admission 전에 검사한다. fixed stack `[max_remote_backend_runtimes]CloseScanReceipt`에 pointer-free handle/runtime/request/ticket을 collect하고 iterator를 닫는다. frozen sweep max/cursor 범위의 다음 16개를 fixed top-16 insertion으로 고르고 Busy에도 cursor를 전진시킨 뒤 매 act 직전 relookup+seal+`CloseOperationPin`을 획득한다. permanent Busy 16+success 17, 4,096/256 tick, ticket 0 미발급·empty start·max-1/max end sentinel, gap/remove/reinsert/new churn, map rehash/ABA, A callback의 B remove/reuse와 same-target self-remove Busy를 검증한다. `closing_count`로 scan을 생략하면 실패한다. |

## 아직 예산이 없는 영역

| 영역 | 이유 | 예정 측정 |
| --- | --- | --- |
| 앱 시작 시간 | macOS host는 있지만 launch → first drawable을 재는 하니스가 아직 없다. | app launch -> first drawable time |
| 입력 지연 | PTY·GUI input path는 있지만 왕복 지연을 재는 하니스가 아직 없다. | key event -> PTY write, PTY output -> snapshot update |
| frame budget | DrawList 빌드(락-보유 구간)는 위 `render_build_*` 예산으로 재지만, snapshot -> GPU frame submit 전체 frame 예산은 아직 없다. future WebGPU backend도 같은 기준을 따른다. | snapshot -> GPU frame submit |
| font/glyph atlas | smoke 수준의 CoreText CPU raster와 Metal texture upload 검증, CoreText smoke의 제품 후보 `coretext_raster.zig` wrapper + smoke native bridge raster bytes 검증, Metal smoke의 제품 `GlyphRasterFrame.uploads/pixels` CoreText bytes -> Metal atlas upload/readback -> shader sampling 검증은 있지만, 제품 renderer의 CoreText raster·atlas grow/eviction/upload **성능** 예산은 아직 없다. 현재 제품 경계는 `GlyphCacheKey -> AtlasSlot -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` 도메인 계약이다. 기본 성능 경로의 `GlyphRasterFrame`은 test rasterizer로 upload byte/skip/sample contract를 고정하고, macOS CoreText/Metal smoke만 native bridge를 주입하므로 제품 CoreText raster 성능을 아직 측정하지 않는다. 경계 밖 slot은 byte buffer를 만들지 않고 skip해 oversized 입력의 메모리 증폭을 막는다. 세부 정책은 [폰트 전략](font-strategy.md)을 따른다. | first glyph resolve, frame당 atlas miss, atlas grow count, atlas upload bytes, raster upload bytes, raster skip count, font size 변경 후 첫 frame |
| control-plane dispatch/backpressure | live pump와 4/32 MiB byte budget은 구현됐고 tick당 최대 1 action·512 KiB, watermark pause/resume를 헤드리스로 고정한다. 실제 ReleaseSafe WKWebView smoke도 pump p95≤0.5 ms/max≤1.0 ms를 수집해 실패 gate로 사용한다. app/WebContent RSS와 bridge/frame-deadline 귀속 artifact는 별도 Track 5 완료 gate에 남아 있다. | JSON-RPC parse/dispatch latency, per-tick processed request count, capture/executeScript chunk copy time, `result_serialized_bytes`, `result_chunk_count`, `result_transfer_ticks`, `result_peak_owned_bytes`, app/WebContent RSS delta, tick당 pump bytes/time, reserved/queued bytes, outbound queue drop/coalesce count, `subscribeOutput` queue latency, slow subscriber disconnect count |
| editor WKWebView/문서 I/O | Monaco 제품 gate가 RED이고 safe-save/watcher/diff API가 미구현이라 숫자 baseline이 없다. bundle bytes만으로 web-process RSS·first interactive·IME latency·대형 파일 copy 비용을 대신하지 않는다. | asset/worker bytes, 1/2/4 editor surface별 web-process RSS·worker 수·hidden CPU·close 후 회수, editor open→text visible/interactive, edit→paint, save bytes/fsync latency, watcher event→hash/conflict, diff page raw/JSON bytes·latency, bridge pending/queued bytes |
| RSS/memory baseline | platform별 측정 API가 필요하다. | cold start RSS, one tab RSS, scrollback RSS |
| session-host slow observer | P5b2b1은 매 owner turn의 logical queue/base/global ledger가 compile-time hard cap을 넘지 않아야 한다. P5b2b2는 독립 ReleaseFast host의 warm baseline 대비 반복-sample run peak와 post-drain RSS를 `session-host-slow-observer-macos.json`에 기록한다. 판정식은 `max(0, run_peak-baseline) <= (peak_ledger_resident - baseline_ledger_resident) + 2 * base_update_max_bytes + 64 MiB`, `max(0, post_median-baseline) <= 같은 analytic cap`이고 validator가 raw sample에서 다시 계산한다. allocator의 즉시 OS 반환이나 post≤pressure peak는 가정하지 않고 논리 회수는 final ledger 0으로 별도 판정한다. | in-process test runner RSS, `ru_maxrss`, `RUSAGE_CHILDREN`, FakeRuntimeOps input 성공만으로 PTY/RSS isolation을 완료 처리하지 않는다. |
| PTY backpressure | opt-in correctness stress는 있지만 대량 stdout 성능 예산은 아직 없다. | large stdout producer -> queue drain latency, UI responsiveness |

## Micro-slice 성능 운영

세션 컨트롤 플레인과 웹 패널 구현은 [control-plane-implementation.md](control-plane-implementation.md) §11의 micro-slice 단위로 진행한다. 각 slice가 hot path를 건드리면 PR 본문에 다음을 남긴다.

- 어떤 경로가 새로 반복 호출되는가(frame tick, PTY pump, socket dispatch, WebView bridge, zntc watch 등).
- 새 allocation/copy/lock/thread hop/I/O가 bounded인지, 어떤 테스트나 artifact로 확인했는가.
- 기존 `mise run perf` 항목과 연결되는지. 연결되면 전후 비교를 남기고, 연결되지 않으면 위 "아직 예산이 없는 영역"에 어떤 metric을 추가할지 적는다.
- queue/backpressure가 있으면 max size, drop/coalesce, slow-consumer disconnect, cleanup/rollback 조건을 함께 검증한다.

숫자 perf의 PR 게이트는 위 여유 있는 guardrail 예산으로만 강제한다(빠듯한 목표치를 required check로 두지 않는다). 그리고 성능 영향을 만든 slice가 아무 artifact 없이 "나중에 측정"으로 넘어가는 것은 허용하지 않는다.

### Mermaid 계측 해석

Native artifact는 ABI v139의 `cold_response_deadline_ms=5000`, `warm_response_deadline_ms=2000`, `reply_fallback_grace_ms=250`, 최대 `reply_fallback_ms=5250`도 직접 기록하고 build gate가 exact 값을 확인한다. 이 검증은 앵커 없는 substring `grep`을 쓰지 않는다 — 그 방식은 `"ticks": 10000`이 기대 `1000`을 부분 문자열로 포함해 통과하던 **예산 10배 false-green**을 냈다. 대신 `tools/perf/validate_json_artifact.zig`가 JSON을 파싱해 스키마·타입·값으로 판정한다: caps·deadline 상수는 exact 일치, 실측 최댓값(`product_tick_max_elapsed_us` 등)은 상한, 카운트는 하한이며, `live-preview-macos` 스키마는 키 집합을 전체 락(누락·추가 키 모두 실패)하고 `mermaid-helper-summary`는 boolean invariant를 타입 검사한다. deadline 선택은 Zig `MermaidCoordinatorState.drainAction`의 `spawn_helper` 판정 하나가 소유하며 Swift는 action의 absolute deadline과 공용 grace 상수만 소비한다. Web mailbox는 별도 timeout을 두지 않는다.


process spawn/terminate·pipe setup/read/write·blocking wait는 실제 operation-site 계측이고 모두 tick 귀속 0이어야 한다. FS·WebView create/destroy·worker wait는 제품과 smoke가 함께 쓰는 concrete `MermaidProductTickAdapter`·`MermaidAcceptedResultDrainer`에서 배제하고 build source-policy gate가 금지 API 유입을 실패시킨다. native perf는 exact 512 KiB accepted SVG를 같은 drainer의 ABI copy·UTF-8 decode 뒤 제품과 공유하는 `MermaidReplyDeliveryAdapter`의 pending identity lookup·response construction·one-shot callback에 통과시키고 callback에서 동일 response object를 JSON 직렬화한다. `accepted_svg_bytes_max=524288`, `product_reply_delivered=true`, delivery 뒤 pending 0, `product_tick_max_elapsed_us<=20000`을 요구한다. 메인 액터 tick(`pump→drainCompletions`)이 worker와 공유하는 `completionLock`을 획득하려고 기다린 시간도 계측한다 — 정상 경로 `product_tick_lock_wait_max_us`, hang/restart/latch 경로 `failure_latch_product_tick_lock_wait_max_us`, 그리고 hang/latch 경로의 whole-tick elapsed `failure_latch_product_tick_max_elapsed_us`를 artifact에 남겨 셋 다 ≤20 ms를 assert한다. 이전엔 정상 경로 whole-tick elapsed만 기록하고 lock 대기와 hang 경로 elapsed는 계측하지 않아 "worker wait 0 / ≤20 ms" 계약이 정상 경로에서만 부분 증명됐다. critical section(배열 swap·카운터 리셋)이 짧아 실 stall 위험은 낮지만, 값을 남겨 회귀를 잡고 계약을 정상·실패 경로 양쪽에서 증명한다. WebKit 내부 IPC serializer 자체는 공개 주입점이 없어 이 결정적 직렬화와 별개이며, 실제 작은 SVG의 WebKit Promise 해소는 `.app` smoke가 맡는다. 이는 OS 전체 activity나 WebKit service CPU를 계측했다는 뜻이 아니다. `macos-app-smoke`는 별도로 signed `.app`의 실제 WKWebView에서 같은 adapter/drainer/reply delivery의 tick/pump/drain 호출과 elapsed budget, 정상 Mermaid request/result 뒤 편집과 실제 `⌘S` 저장을 먼저 검증한다. 그 뒤 test-only hang request를 같은 isolated bridge로 제출해 helper in-flight를 관측하고 실제 `WKWebView.reload()`을 발생시켜 provisional navigation callback 1회·pending reply 0·deadline 1을 고정한다. 이 마지막 reload는 editable document recovery latch를 의도적으로 세우므로 저장 검증 뒤에만 실행하며, 정상 render와 hang을 합친 helper request는 2회다.

## 향후 목표 초안

이 값은 구현이 붙은 뒤 검증하며 조정한다.

| 항목 | 초안 |
| --- | --- |
| cold start to first window | 150ms 이하 목표 |
| first shell prompt | 300ms 이하 목표 |
| key input local echo path | p95 8ms 이하 목표 |
| steady frame budget | 120Hz 기준 8.3ms 안쪽 목표 |
| one idle tab RSS | 측정 후 기준 확정 |
| large scrollback memory | page storage 설계 후 기준 확정 |

## Session-host reconnect 관측 예산

실행 중 transport reconnect는 정상 frame hot path에 incident 직렬화나 disk I/O를 추가하지 않는다. 최초 typed poison에서만
fixed-size `ConnectionIncident`를 만들며 Release의 disk 실패 경로는 process 시작 때 미리 할당한 32 KiB emergency ring을 써
추가 allocation 없이 scheduling 전에 handoff한다. stable `ScreenSource` proxy는 정상 render borrow마다 gate 하나를 거치므로
CR2b benchmark는 gate 획득 시간, render critical-section, writer-pending 뒤 신규 reader 수, reconnect publish wait를 각각
기록한다. 숫자 예산은 구현 전 baseline 대비 회귀율로 먼저 고정하고, 측정 없이 "영향 없음"으로 완료 처리하지 않는다.
기능 exact gate는 writer-pending publish 뒤 신규 reader admission 0, nested lock 0, configured absolute deadline을 넘긴 publish
wait 0이다. latency p50/p99 상한은 CR2a baseline artifact에 수치와 하드웨어 조건을 기록한 뒤 CR2b 착수 전에 확정한다.
