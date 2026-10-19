# Terminal Inspector

실행 중 터미널의 관측 상태를 읽는 진단 화면이다. View → Terminal Inspector,
명령 팔레트, 기본 단축키 `⌥⌘I`로 연다. `toggle_inspector` 키바인딩을 변경하거나
unbind할 수 있다. 파일·SCM 도크와 별개인 독립 도구 화면이며 모달이나 workspace Pane이 아니다.
상·하·좌·우 배치와 구분선 크기 조절, 별도 OS 창으로 분리·재도킹을 지원한다. 터미널과 진단 화면을 동시에 사용할 수 있다. Trace 파일의 단계별 HTML replay 뷰어와는 별개다.

검사 대상은 선택한 **터미널 surface의 관측 상태**다. UI 컴포넌트 tree를 탐색하거나,
화면 요소를 가리켜 bounding box와 layout/style 속성을 표시하는 요소 선택기는 이 계약 밖이다.

## GUI와 CLI의 공통 계약

`src/session/inspector/snapshot.zig`의 `Snapshot`을 macOS 어댑터가 수집한다.
GUI와 CLI는 동일한 `maru.inspector.v1` JSON 구조를 사용한다. 샘플 시각은 서로
다를 수 있다. 식별자·경로를 추측하지 않으며 가용성·출처·선택 이유를 함께 제공한다.

```sh
maru sessions list
maru session inspect <surface-id> --json
maru session inspect <surface-id> --json --anonymize > report.json
```

ID는 GUI surface ID다. session-host runtime ID와 혼용하지 않는다.
`inspect`는 `session.get`의 선택적 `inspect:true` 확장을 사용한다. 기존 get 응답에는
확장을 요청하지 않는 한 inspector 필드가 없다. 앱이 실행 중이어야 한다.
구버전 앱 또는 터미널 이외 대상은 지원하지 않는다는 오류를 돌려준다.

| 탭 | JSON 키 | 내용 | 수집 원천 |
| --- | --- | --- | --- |
| Overview | `overview` | surface/runtime·창·탭·pane, backend, 관측 가용성·revision·generation·시각 | AppSession의 선택 Term, runtime observation |
| Path/SSH | `path` | 최종 cwd와 출처·이유, OSC 7, 훅 cwd·host·신선도, SSH 목적지, 원격 SCM 후보 판정, 창의 Explorer 표시 상태 | 기존 cwd/SCM 결정 함수, OSC7 관측, agent hook slot, 파일 트리 상태 |
| Terminal | `terminal` | 크기·커서·모드·semantic prompt·foreground pgid, 지원하는 scroll region | runtime observation과 lock 아래 renderSnapshot/core |
| Events | `events` | 첫 진단 이후의 유한 이벤트 기록, 샘플 변경과 셸 protocol 이벤트 구분, eviction 수 | 유계 history의 sample 변화와 활성 local OSC7/133 drain |

Explorer 값은 대상 터미널 소유의 경로가 아니라 **그 창이 현재 표시하는 상태**다.
Pin으로 다른 터미널을 고르면 대상의 cwd와 창의 Explorer root가 다를 수 있다.
원격 SCM 후보는 실제 열린 저장소라는 보장이 아니라 기존 SCM 선택 조건의 판정 결과다.

## 조작

Previous/Next로 터미널을 선택하면 Pin한다. Follow는 활성 터미널을 따른다.
Live는 어댑터의 poll 간격으로 갱신하고 Paused는 진단 화면만 멈춘다.
Refresh는 일시정지 중에도 새 스냅샷을 수집한다. 닫힌 고정 대상은 마지막 스냅샷과
대상 종료 상태를 보존한다. 필터를 클릭한 뒤 타이핑하거나 붙여넣어 항목을 좁힌다. 열기만 하면 키보드 포커스는
터미널에 남는다. 터미널을 클릭하면 필터 포커스를 해제한다.
필터 위 커서는 텍스트 입력 모양, 버튼·탭 위는 손 모양, 본문은 화살표다.
붙어 있는 도크의 구분선은 방향에 맞는 좌우·상하 크기 조절 커서를 사용한다.
분리 창에서도 같은 필터·버튼·본문 판정을 사용하며 view 밖으로 이동하면 화살표로 복원한다.
버튼 hover 배경은 view·Inspector 영역을 벗어나거나 창 focus를 잃으면 해제한다. 커서 복원과 별개인 paint 상태다.
필터에 포커스가 있을 때 Tab/Shift-Tab은 탭 이동, 방향키·Page Up/Down은 스크롤이다.
wheel은 도크 위에서만 진단 목록을 스크롤한다. Escape는 필터를 먼저 지우고 다시 누르면
붙어 있는 경우 터미널로 포커스를 돌린다. 분리 창에서는 필터만 해제하며,
창이 키보드 포커스를 가진 동안 인스펙터가 입력을 소유한다. `⌥⌘I` 또는 닫기 버튼으로 인스펙터를 닫는다. 필터 포커스 또는 분리 창 포커스 중 `⌘W`도 인스펙터를 닫는다.

필터 포커스 중 `⌘C` 또는 Copy JSON은 현재 스냅샷, 필터 포커스 중 `⌘S` 또는 Save는
`~/.cache/maru/inspector/snapshot-<surface>-<time>.json`을 저장한다.
GUI export는 기본 익명화이며 화면의 export 행에서 원본으로 바꾼다.
파일은 소유자 읽기/쓰기 권한으로 새로 만든다. CLI는 원본이 기본이며 `--anonymize`로
같은 익명화 함수를 적용한다. 익명화는 JSON 키를 보존하고 문자열 값에 적용한다.
홈·사용자명 치환은 모든 민감한 경로나 원격 식별자 제거를 보장하지 않는다.

## 권한과 수집 한계

창의 Explorer 진단은 다른 pane의 정보를 담을 수 있으므로 metadata `all` scope를
요구한다. self/window scope는 대상 존재 여부를 확인하기 전에 동일하게 거부한다.
CLI inspect는 기존 same-UID·selector 없는 전체 metadata 조회 정책을 사용한다.
PTY 입력·출력 원문을 수집하거나 터미널 모드를 변경하지 않는다.

`runtime_id`는 session-host runtime이 있을 때의 값이며 in-process 터미널에서는 null이다.
GUI collector는 현재 window membership ID를 받지 않아 `overview.window`가 null이고, CLI collector는
실제 membership ID를 제공한다. 화면의 공통 “정보 없음” 표시는 해당 없음·미수집·미지원 이유를
구별하지 못하므로 이 값만 보고 관측 실패라고 단정하지 않는다.

이벤트는 `History.capacity`로 제한한다. 샘플링 사이에 변한 값은 놓칠 수 있다.
로컬 protocol 이벤트는 기존 활성 터미널의 OSC 7/133 drain을 관측한 기록이며
원래 PTY 수신 시각·모든 원시 바이트의 로그가 아니다. SSH 변경은 샘플 변화다.
호스트는 원시 셸 이벤트와 scroll region을 전달하지 않으므로 해당 항목을 미지원으로
표시한다. cursor는 실제 host screen 경로를 사용한다. 이 화면은 SSH 경로 판정을
설명하며 그 정책을 변경하지 않는다.

구현 단계는 [계획](plans/terminal-inspector.md), 검증 근거는
[검증 매트릭스](verification-matrix.md)의 Live Terminal Inspector 절을 따른다.

## 화면 구성

Chrome DevTools의 [공식 overview와 화면](https://developer.chrome.com/docs/devtools/overview/)을
시각 레퍼런스로 삼는다. reference 구현 소스를 사용하지 않으며 Maru의 토큰과 픽셀 tree로 구성한다.
상단은 대상 이동·Follow/Pin·Live/Paused·Refresh·닫기, 다음 줄은 밑줄로 선택을 구분하는 탭이다.
필터와 속성/값 표는 별도의 띠로 나누고, 세션·관측·셸 통합·훅·라우팅을 섹션 제목으로 구분한다.
이벤트는 sequence·관측 시각·kind·origin·revision을 한 행에 모은다.
하단에는 익명화·Copy JSON·Save를 둔다. 좁은 도크는 제목과 제어 행을 나누고, 넓은 도크는 한 줄로 합쳐 하단 배치의 본문 공간을 확보한다.
진단 키의 UI 표기는 공백과 대소문자로 읽기 쉽게 만들고, 필터는 원래 키와 표시명·값을 모두 검색한다.
JSON schema와 CLI는 표시 변경의 영향을 받지 않는다.

인스펙터 텍스트는 기존 `font.family`/fallback 전략을 따르는 CoreText 측정 아티팩트로
픽셀 위치와 role line box를 보존한다. 캐시는 기하·테마·배율·font face를 함께 구분한다.
`collectMeasuredTextFromCache` 경로와 인스펙터 전용 viewport를 사용한다.
GPU scene tag 6이 인스펙터 배경·글자를 구분한다. 도킹 상태에서는 같은 창에 합성하고,
분리 상태에서는 주 창에서 scene 6을 제외하며 별도 CAMetalLayer에서 scene 6만 표시한다.
두 창은 같은 renderer/atlas와 retained frame을 사용하며 별도 AppSession·PTY를 생성하지 않는다.
모달 프레임을 만들지 않으며 live 렌더와 스크린샷은 같은 합성 경로를 사용한다.

## 독립 배치와 수명

배치 화살표 ↑ → ↓ ← ↗는 위·오른쪽·아래·왼쪽·별도 창을 선택한다. 배치를 옮겨도
대상 ID·Pin·Paused·필터·마지막 스냅샷은 유지한다. 같은 소유 창에서 마지막으로 선택한
터미널을 Follow하며 인스펙터 자체를 선택해도 대상은 바뀌지 않는다. 파일·SCM 도크의
선택·가시성·내용은 인스펙터 배치로 변경하지 않는다. 이 버전의 진단 대상은 터미널이다.

분리 창의 닫기 버튼은 인스펙터만 닫는다. 소유 창이 해제되면 분리 창도 먼저 닫아
해제된 AppSession을 읽지 않는다. 재도킹은 기존 분리 창을 회수하고 같은 스냅샷을 사용한다.
별도 창은 일반 workspace 창 inventory·restore·마지막 터미널 창 종료 판단에 포함하지 않는다.
배치·열림은 현재 소유 창 수명 동안 유지하는 임시 UI 상태이며 workspace 저장 포맷을 바꾸지 않는다.

레이아웃 정책은 중립 `session/inspector/layout.zig`, 제품 상태·입력·수집은 macOS adapter,
NSWindow 생성·닫기·실제 drawable 배율 전달은 Swift가 소유한다. ABI v231은 배치·입력·
read-only control rect/target 관측을 전달하며 JSON schema `maru.inspector.v1`은 유지한다.

## UX 레퍼런스와 결정 기준

사용자 지정 레퍼런스는 Ghostty와 Chrome DevTools다. 공개 문서와 동작을 비교하며 reference
구현의 소스 표현을 복사하지 않는다. 기존 계약을 바꾸는 결정은 사용자와 먼저 논의한다.

- [Ghostty Inspector action](https://ghostty.org/docs/config/keybind/reference#inspector): terminal inspector의
  표시/숨김 조작을 참고한다. Maru의 공개 action 이름은 `toggle_inspector`다.
- [Chrome DevTools placement](https://developer.chrome.com/docs/devtools/customize#placement): 오른쪽·아래·왼쪽
  dock, 별도 window, 마지막 위치 복원을 참고한다. **위쪽 dock은 사용자 승인에 따른 Maru 확장**이다.
- 필터와 terminal의 Escape 경계, Follow/Pin/Paused, export 익명화·권한은 이 문서의 Maru 계약을 따른다.
  Chrome의 Drawer Escape 동작을 별도 Drawer가 없는 현재 Inspector에 그대로 옮기지 않는다.
