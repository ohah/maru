# 헤더 hover 판 시각 골든

`tools/header-hover/capture.sh` 가 **실제 앱**(Swift host + app_session + 제품 Metal 렌더)으로 찍은 프레임의 **타이틀바 띠
부분**이다. 비교는 `tests/golden/header_hover_visual.zig` 가 한다. 창은 기본 960×600(1x) · 1920×1200(2x — 배율 주입
`MARU_SCREENSHOT_RENDER_SCALE_MILLI=2000`)이다.

PPM 은 사람이 diff 로 못 읽으므로([`tests/golden/README.md`](../../../golden/README.md)) **무엇이 찍혀 있어야 하는지**를
여기 적는다. 갱신할 때는 이 목록과 대조해 눈으로 확인하고 커밋한다 — 자동 갱신(`MARU_UPDATE_GOLDEN=1`)은 회귀를 골든으로
굳힐 수 있다.

## 잘라낸 사각형(1x 기준, 2x 는 두 배)

| 이름 앞머리 | 사각형 | 담는 것 |
|---|---|---|
| `header-*` | `x∈[72,180) y∈[0,34)` | 펼친 사이드바 헤더의 종 · ◧ · ⚙ · + 와 그 hover pill, 띠(28px) 아래 6px |
| `collapsed-toggle-*` | `x∈[106,150) y∈[0,34)` | 접힌 사이드바의 종(왼쪽 일부) · ◧ 와 그 hover pill, 접힘 띠(30px) 아래 4px |
| `dock-toggle-*` | `x∈[912,960) y∈[0,34)` | 타이틀바 띠 오른쪽 끝 파일 도크 토글 ◧ 와 그 판(= 클릭 사각형), 띠 아래 6px |

**글꼴을 타는 것은 일부러 뺐다** — 검색 줄 글자(헤더 아래), 탭 제목(접힘 띠 아래), 접힌 ◧ 왼쪽의 알림 숫자. 헤더 아이콘은
글꼴이 아니라 합성 PUA 라 러너의 글꼴 구성에 흔들리지 않는다.

## 장마다 있어야 하는 것

| 장 | 있어야 하는 것 |
|---|---|
| `header-none-{1x,2x}` | 아이콘 넷만 있고 **판이 없다**(hover 없음의 기준) |
| `header-toggle-{1x,2x}` | ◧ 뒤에 밝은 둥근 pill. pill 가운데가 ◧ 가운데이고, **위는 창 끝에 닿되 잘리지 않고 아래는 띠 안에서 끝난다**(2x 에서 예전 63px pill 이 56px 띠를 넘어 위 4px 가 평평하게 잘렸다 — #4421) |
| `header-view-options-{1x,2x}` | ⚙ 뒤에 같은 pill |
| `header-new-workspace-{1x,2x}` | + 뒤에 같은 pill |
| `header-bell-{1x,2x}` | 종 뒤에 같은 pill. 종은 2칸이라 pill 중심이 반 칸 오른쪽(#4392·#4394) |
| `collapsed-toggle-{1x,2x}` | 접힌 ◧ 뒤에 pill — 접힘 띠(1x 30px · 2x 60px) 안에서 끝난다 |
| `dock-toggle-{1x,2x}` | ◧ 뒤에 **사각** 판(둥글지 않다 — 클릭 사각형을 그대로 칠한다). 판은 띠에서 멈추고 아래 탭 바로 새지 않는다(2x 에서 예전 59px 로 3px 샜다 — #4410) |

## 결정성

같은 트리에서 두 번 찍어 비교한 실측(2026-10-13): 14장 모두 화면 위 10%(이 사각형들이 사는 곳)는 **0 픽셀** 차이였다.
차이는 화면 가운데 글자 한 줄(y 75~89)에서만 났다 — 이 게이트가 보지 않는 곳이다. 그래서 잡음 예산을 두지 않는다
(채널 허용 2 는 이웃 게이트와 같은 값).

결정성을 위해 캡처 스크립트가 박는 것: 앱마다 따로 두는 `HOME` 과 세션 host 루트(`MARU_SESSION_HOST_ROOT`),
`ui.language = ko`, 아무것도 안 그리는 셸(`exec sleep`), `session.keep-alive-after-quit = false`.
