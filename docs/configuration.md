# 설정(config) 파일

Maru는 시작 시 사용자 설정 파일을 읽어 폰트·색·커서를 적용한다. 이 문서는 파일 위치, 형식, 키,
검증 동작을 정한다. 설정은 **선언적**이고 **forgiving**하다 — 설정 파일이 없거나 일부 줄이 틀려도
터미널은 정상 동작한다.

> 이 문서는 config 토대의 appearance(폰트/테마/커서) + 키바인딩 파싱을 다룬다. 메뉴의 수동 Reload Config·
> Reset to Defaults는 구현됐고, schema 기반 설정 UI는 진행 중이다([세팅 페이지 전략](settings-page.md)).
> 파일 변경 자동 감지 reload와 남은 bespoke 위젯은 후속 단계다(아래 "범위와 후속" 참조).
> 수동 reload의 scrollback·ambiguous/emoji width·ANSI palette·default color·cell metric snapshot은 열린
> in-process terminal과 `runtime_core_command_v1`을 협상한 현재 host-backed terminal에 적용된다. capability
> 없는 구 host의 기존 runtime은 legacy scroll 외 config command가 degraded no-op이다. 새 host-backed terminal은 같은 snapshot을
> `runtime.spawn_full`에 실어 reader 시작 전에 적용하므로 첫 output도 기본값으로 먼저 parse되지 않는다.
> 이 계약의 capability가 없는 이미 실행 중인 구 session host는 새 필드를 조용히 무시할 수 있으므로 config-bearing
> spawn을 거부하고 in-process terminal로 명시적으로 fallback한다. 잘못된 기본값으로 host runtime을 만들지 않는다.

## 위치

다음 순서로 경로를 정한다.

1. 환경변수 `$MARU_CONFIG`가 있으면 그 경로.
2. 없으면 `$HOME/.config/maru/config`.
3. `$HOME`도 없으면 설정 없이 기본값으로 시작한다.

파일이 없으면 **에러가 아니라** 전부 기본값으로 시작한다(Ghostty와 같은 위치/관례).

## 형식

`key = value` 한 줄에 하나. `#`로 시작하는 줄과 빈 줄은 무시한다(Ghostty식). 값은 양끝 공백을
다듬되 **내부 공백은 보존**한다(예: 폰트명 `JetBrains Mono`). 따옴표는 쓰지 않는다.

```conf
# ~/.config/maru/config — 예시
font.family = JetBrains Mono
font.size = 14
font.line-height = 1.0
font.letter-spacing = 0.0

# 컬러 테마 프리셋(선택). 한 줄로 색 세트를 고른다.
# maru(기본)·ghostty·gruvbox-dark·solarized-dark·solarized-light·dracula·catppuccin-mocha·catppuccin-latte·light-pink·
# dark-pink·rose-pine·rose-pine-dawn·tokyo-night·nord·one-dark·one-light.
# 프리셋은 base다 — 아래 개별 theme.* 키를 프리셋 줄 *뒤에* 두면 그 색만 덮어쓴다.
theme.preset = maru

theme.background = #101010
theme.foreground = #e8e8e8
theme.cursor     = #ffffff
theme.selection  = #334455
# ANSI 16색 override(선택, 인덱스 0~15). 적은 인덱스만 덮으면 나머지는 xterm 표준색.
theme.palette.0  = #1c1c1c
theme.palette.1  = #d35f5f
# theme.min-contrast = 3.0   # 가독성 하한(WCAG 명암비) — 전경이 안 읽히면 밝은 배경에선 어둡게·어두운 배경에선 밝게. 0=끔

cursor.shape = block              # 기본 모양 — 앱 DECSCUSR가 지정하면 그게 우선(CSI 0 SP q·RIS면 이 값 복귀)
cursor.blink = true               # true=앱(DECSCUSR)에 위임, false=앱 요청까지 덮어 커서 고정
cursor.blink-interval-ms = 500   # 깜빡임 반주기(ms) — cursor.blink=true일 때
# cursor.blink-fade-ms = 120      # 깜빡임 전환 페이드(ms) — 기본 0(즉각 on/off), 값을 주면 부드럽게
# 커서 색 override(선택). 적으면 테마와 무관하게 커서만 그 색으로 칠한다. 안 적으면 테마를 따른다.
# cursor.color = #ff5555   # 커서 칸 배경(미지정 시 theme.cursor)
# cursor.text  = #101010   # 커서 위 반전 글자색(미지정 시 배경색)

window.padding-top    = 4
window.padding-right  = 8
window.padding-bottom = 4
window.padding-left   = 8
# 또는 대칭 alias: window.padding-x = 8 (좌우 동시), window.padding-y = 4 (상하 동시)
window.opacity        = 1.0   # 배경 투명도(0~1) — default 배경만 투명, 1=불투명
render.frame-rate     = 60    # 앱 frame-loop 주사율(Hz) — 30~120, 기본/권장 60
window.background-image =      # 배경 이미지 PNG 경로(절대경로) — 비면 없음
window.blur           = 0     # 창 뒤 데스크톱 블러 반경(px) — 0=끔, opacity<1일 때만
window.unfocused-dim  = 0.0   # 비활성 split pane 디밍(0~1) — 0=끔, 클수록 흐림
split.divider-thickness = 1.0 # split 경계선 두께(pt) — 0=숨김, 폰트 크기와 무관한 고정 pt
file-panel.external-link-target = in-app # 파일 패널 외부 링크: in-app | system
```

## 키

| 키 | 타입 | 기본값 | 비고 |
|---|---|---|---|
| `font.family` | 문자열 | `JetBrains Mono` | 내부 공백 보존. 비어 있으면 무시(기본 유지) |
| `font.fallback` | 문자열(쉼표 구분) | (없음) | **폴백 폰트** 목록(예: `Apple SD Gothic Neo, Apple Color Emoji`). 주 `font.family`에 없는 글리프(한글·이모지·기호 등)를 그릴 때 이 목록을 앞에 두고 CoreText 기본 폴백을 뒤에 잇는다(`kCTFontCascadeListAttribute`). 각 항목은 앞뒤 공백 trim(내부 공백 보존). 잘못된 폰트명은 무시(best-effort). 비어 있으면 CoreText 기본 폴백만 |
| `font.family-bold` | 문자열 | (없음) | **bold(SGR 1) 글자용 폰트 패밀리**. 비어 있으면(기본) 주 `font.family`의 bold variant를 쓴다(variant가 없으면 regular 폴백 — 굵기를 합성하지 않음). 설정하면 bold cell을 이 패밀리로 그려 본문과 다른 글꼴로 강조할 수 있다. `font.fallback` cascade를 상속해 bold 한글·이모지도 폴백한다. 패밀리를 못 찾으면 주 폰트 bold로 폴백(best-effort) |
| `font.family-italic` | 문자열 | (없음) | **italic(SGR 3) 글자용 폰트 패밀리**. 비어 있으면(기본) 주 `font.family`의 italic variant를 쓴다(없으면 regular 폴백). italic 렌더는 이 기능과 함께 추가됐다(이전엔 SGR 3이 기울임으로 안 그려짐). bold+italic은 bold face(`font.family-bold` 또는 주 폰트 bold)에 italic을 더한다. 패밀리를 못 찾으면 주 폰트 italic로 폴백 |
| `font.size` | 숫자 | `14` | 1~512 범위. 범위 밖/비숫자는 무시. ⌘+/⌘-(Bigger/Smaller)는 이 값을 **고정 1pt씩** 바꾸고 ⌘0(Actual Size)이 복귀시킨다(보폭은 설정 불가) |
| `font.line-height` | 숫자 | `1.0` | 행간 배수. 1.0=CoreText 자동 cell 높이, 1.5=50% 더 큰 줄 간격. 0.5~3.0 범위. 범위 밖/비숫자는 무시. 늘어난 높이는 글자를 셀 안 세로 가운데로 그려 위아래 여백이 된다 |
| `font.letter-spacing` | 숫자 | `0.0` | 자간(논리 pt). 0=advance 그대로, 양수=칸 넓힘, 음수=칸 좁힘. -8~32 범위(음수 허용). 범위 밖/비숫자는 무시. 늘어난 폭은 글자를 셀 안 가로 가운데로 그려 좌우 여백이 된다 |
| `theme.preset` | 프리셋 이름 | `maru` | 이름 붙은 컬러 테마 **base**. 색 세트(배경/전경/커서/선택 + ANSI 16색)를 한 번에 고른다. `maru`·`ghostty`·`gruvbox-dark`·`solarized-dark`·`solarized-light`·`dracula`·`catppuccin-mocha`·`catppuccin-latte`·`light-pink`·`dark-pink`·`rose-pine`·`rose-pine-dawn`·`tokyo-night`·`nord`·`one-dark`·`one-light`. 개별 `theme.*` 키를 **이 줄 뒤에** 두면 그 색만 override(순차 적용, 나중 줄 우선). 그 외 값은 무시. 아래 [컬러 테마 프리셋](#컬러-테마-프리셋-themepreset) 참조 |
| `theme.follow-system` | `true`\|`false` | `false` | **시스템 라이트/다크 외관을 따라 테마 색을 자동 전환**한다. `true`면 macOS가 라이트면 `theme.preset-light`, 다크면 `theme.preset-dark` 색 세트로 라이브 교체하고 외관이 바뀌면 즉시 따라간다. **켜져 있는 동안 `theme.preset`·개별 `theme.*` 색은 무시**되고 시스템이 색을 정한다(끄면 파일의 그 값으로 복귀). 시스템 외관 교체는 config 파일에 영속하지 않는다. 기본 `false`(현행 — 수동 테마) |
| `theme.preset-light` | 프리셋 이름 | `solarized-light` | `theme.follow-system`이 켜졌을 때 **라이트** 외관에 쓸 프리셋(위 `theme.preset`과 같은 이름 집합). 라이트 테마(`solarized-light`·`catppuccin-latte`·`light-pink`·`rose-pine-dawn`·`one-light`)를 권장 |
| `theme.preset-dark` | 프리셋 이름 | `maru` | `theme.follow-system`이 켜졌을 때 **다크** 외관에 쓸 프리셋. 다크 테마(`maru`·`gruvbox-dark`·`dracula`·`tokyo-night`·`nord`·`one-dark`·`rose-pine`·`dark-pink` 등)를 권장 |
| `theme.background` | `#RRGGBB` | `#101010` | 16진 색. 형식 오류는 무시 |
| `theme.foreground` | `#RRGGBB` | `#e8e8e8` | |
| `theme.cursor` | `#RRGGBB` | `#ffffff` | |
| `theme.selection` | `#RRGGBB` | `#334455` | 선택 하이라이트 배경 |
| `theme.palette.0`~`theme.palette.15` | `#RRGGBB` | xterm 표준색 | ANSI 16색(0~15) override — `ls`/`vim`/프롬프트 색 테마 완성용. 적은 인덱스만 덮어도 됨(나머지는 xterm 표준 폴백). 우선순위는 **OSC 4(앱 동적 설정) > config > xterm256**: 앱이 OSC 4로 색을 바꾸면 그게 우선이고, RIS·OSC 104(리셋) 후엔 다시 이 config 값으로 돌아온다. 범위 밖 인덱스(16+)·비정수 인덱스·형식 오류 색은 무시(그 인덱스는 기본 유지) |
| `theme.bold-is-bright` | `true`\|`false` | `false` | bold(SGR 1) 글자의 ANSI **indexed 전경(0~7)** 을 그 bright 짝(8~15)으로 올린다. `.default` 전경·`.rgb`·256색 cube(8~255)는 안 바꾼다(정의가 분명한 부분집합만). reverse(7)/conceal/blink-off 경로엔 적용 안 함(그 경로는 배경색을 그림). render-only(코어 셀·SGR 상태 불변). 베이스: xterm `boldColors`·Ghostty `bold-is-bright`와 같은 opt-in 트레이드오프 |
| `theme.min-contrast` | 실수(0.0~21.0) | `3.0` | **자동 대비 게이트** — 전경색이 배경 대비 이 명암비(WCAG contrast ratio)에 못 미치면 **색상(hue)은 보존한 채, 목표에 막 닿는 최소 변화량만** 보정해 읽히게 한다(이미 충분한 색은 무변경). `0`(또는 `1` 이하)=끔. 기본 `3.0`=WCAG 대형 텍스트/UI 컴포넌트 기준, 더 강한 대비는 `4.5`(WCAG 일반 텍스트 AA)로 올린다. **maru는 이 게이트를 켜서 출고한다**(Ghostty의 같은 기능 `minimum-contrast`는 기본이 `1`=끔). 켜서 출고하는 이상 보정이 기본 설정 전체에 닿으므로 **어둡게 하는 방향은 넓게, 밝히는 방향은 좁게** 연다. 적용은 **두 겹**이다: ① **ANSI 16색 팔레트**(프리셋·`theme.palette.N`·xterm 기본색)는 config resolve 시점에 선보정되고 OSC 4 팔레트 질의 응답도 이 보정값을 보고한다(화면과 보고 일치). 이 레이어는 **어둡게만** 보정한다 — 같은 팔레트가 ANSI **배경색**(SGR 40~47)으로도 나가므로 밝히면 다크 테마의 배경색이 회색으로 떠버린다. 따라서 **충분히 어두운 배경(번들 다크 프리셋)에선 팔레트 선보정이 무동작**이다(경계: 배경 luminance ≈ 0.05×(목표−1), 기본 3.0이면 ≈0.10). explicit `theme.palette.N`도 함께 적용되며, 원색 그대로 원하면 `0`으로 끈다. ② **렌더 per-cell 전경**은 프로그램이 escape로 직접 고르는 색이라, 렌더가 셀 단위로 **실제 칠해지는 배경**(선택/검색 하이라이트가 있으면 그 색, 없으면 reverse 반영한 자기 셀 배경) 기준으로 하한을 강제한다. **어둡게** 하는 보정은 모든 전경에 적용된다(라이트 배경에서 안 보이는 밝은 색 — truecolor 밝은 회백색을 본문에 쓰는 프로그램 등). **밝히는** 보정은 아래를 **전부** 만족할 때만 적용한다: **⒜ 셀에 명시 배경이 없고**(SGR 40~47/48 배경 셀 제외 — powerline 세그먼트·diff 블록의 의도한 색 조합 보존), **⒝ 전경이 truecolor 또는 256색 cube**(ANSI 16색·default 제외 — 번들 테마 팔레트·OSC 4 응답·theme 색은 프리셋의 선택이라 렌더가 안 뒤집는다), **⒞ faint(SGR 2)·reverse가 아님**(의도적 감쇠·반전 보존). 이 교집합이 겨냥하는 것은 **라이트 테마를 가정하고 truecolor로 색을 고른 프로그램이 다크 터미널에서 본문이 배경에 묻히는 경우**다(예: 실행 중에 터미널 테마를 바꾼 Claude Code 세션 — 그런 프로그램은 시작 시 배경을 한 번 감지해 팔레트를 고정하므로 종료 전까지 이전 테마용 색을 계속 쓴다). per-cell 보정은 렌더 전용이라 OSC 4/10/11 질의 응답엔 반영되지 않고, conceal(SGR 8)·blink-off(의도적 비표시)와 powerline/box/block 도형 글리프(이웃 셀과 색 이어붙임 이음매)는 제외한다. 밑줄·취소선 등 장식선은 셀 배경을 캐리하지 않아 **어둡게만** 보정한다(밝히면 글리프와 어긋난다). theme의 배경·전경(default)·커서·선택색은 안 바꾼다. 범위 밖/비실수는 무시(기본 유지) |
| `cursor.shape` | `block`\|`bar`\|`underline` | `block` | 커서 **기본** 모양. 앱이 `DECSCUSR`(`CSI Ps SP q`)로 모양을 지정하면 그게 이기고(vim이 normal/insert 모드마다 block↔bar를 바꾸는 표준 수단 — 설정이 이걸 덮으면 편집 모드 구분이 사라진다), 앱이 `CSI 0 SP q`로 지정을 거둬들이거나 `RIS`(`ESC c`)로 리셋하면 이 값으로 돌아온다. 즉 "아무도 지정하지 않았을 때의 모양"이다. 베이스: Ghostty `cursor-style`(같은 "설정=기본값" 모델). 설정을 바꾸면 라이브 터미널에도 즉시 반영되지만, **앱이 DECSCUSR로 모양을 지정 중인 터미널은 건드리지 않는다**(편집 중 커서가 튀지 않게). 그 외 값은 무시. `cursor.blink`가 "끔"을 강제하는 것과 달리 이 키가 기본값인 이유: blink는 사용자가 껐으면 끈 것이지만, 모양은 앱이 상태를 표현하는 수단이라 뺏으면 정보가 사라진다 |
| `cursor.blink` | `true`\|`false` | `true` | 커서 깜빡임. `true`(기본)=**앱에 위임** — 실제 깜빡임은 앱의 `DECSCUSR`(`CSI Ps SP q`)가 정하고(vim의 모드별 blink/steady 전환이 그대로 산다), 아무도 안 보내면 터미널 기본대로 깜빡인다. `false`=앱의 DECSCUSR blink 요청까지 **덮어** 커서를 고정(끈 사람이 모드 전환마다 깜빡임이 되살아나길 원하지 않으므로). 베이스는 Ghostty `cursor-style-blink`지만 그쪽은 `?bool`(`null`=무의견)이라 값이 있어도 DECSCUSR를 존중한다 — maru는 `bool`이라 "끔"의 의미를 우선했다. 오버레이(⌘F 찾기·⌘K 팔레트) 입력 caret은 이 설정과 무관하게 깜빡인다(텍스트 입력 caret 관용) |
| `cursor.blink-interval-ms` | 정수(100~10000) | `500` | 커서 깜빡임 **반주기**(밀리초) — on/off 각 단계 길이(500이면 0.5초 켜짐·0.5초 꺼짐). host frame-loop tick으로 환산(반올림, 최소 1틱)하므로 주사율을 바꿔도 실제 깜빡임 시간은 유지된다. `cursor.blink = false`면 이 값과 무관하게 안 깜빡인다. 범위 밖/비정수는 무시(기본 유지). Ghostty `cursor-blink-interval` 대응 |
| `cursor.blink-fade-ms` | 정수(0~1000) | `0` | 커서 깜빡임 **전환 페이드**(밀리초) — on↔off를 이 시간에 걸쳐 알파 램프로 부드럽게 잇는다(각 반주기 끝에서 커서가 서서히 사라지고 나타남). **기본 `0`이면 페이드 없이 즉각 on/off**(터미널·에디터 표준 — xterm은 `cursorOnTime` 600ms/`cursorOffTime` 300ms를 그냥 토글하고, VS Code `editor.cursorBlinking`도 기본이 `blink`이며 페이드는 `smooth`/`phase` opt-in이다). 값을 주면 그만큼 부드럽게 잇는 대신 커서가 완전히 켜져 있는 시간이 줄어 체감상 느리고 흐릿해진다. 반주기(`blink-interval-ms`)를 넘으면 반주기로 clamp된다(같으면 hold 없는 삼각파). host frame-loop tick으로 환산하므로 주사율(`render.frame-rate`)과 무관하게 같은 속도로 페이드한다. `cursor.blink = false`면 무관. |
| `cursor.color` | `#RRGGBB` | (없음) | 커서 칸 배경색을 테마와 **독립적으로** override(opt-in). 미지정이면 `theme.cursor`를 따른다. 형식 오류는 무시(미지정 유지) |
| `cursor.text` | `#RRGGBB` | (없음) | 반전 블록 커서 **위 glyph 색** override(opt-in). 미지정이면 기존 동작(메인 터미널은 배경색, 사이드바 caret은 사이드바 배경색)을 따른다. 형식 오류는 무시 |
| `cursor.unfocused` | `block`\|`hollow`\|`hidden` | `block` | 창이 **포커스를 잃었을 때** 커서. `block`(기본)=현행대로 채운 커서 유지, `hollow`=빈 사각형 테두리(외곽선 — 비활성 창임을 시각적으로, iTerm2/Terminal.app 관례), `hidden`=안 그림. 포커스 있으면 항상 `cursor.shape`대로. 그 외 값은 무시(기본 유지) |
| `window.padding-top` | 정수(0~256) | `4` | 셀 그리드와 pane 가장자리 사이 **위** 여백(논리 pt, DPI 스케일). 탭 바·split divider·pane 배경 등 chrome은 사이드바 경계/창 가장자리까지 꽉 차고 셀 그리드만 들인다. 0이면 셀이 가장자리에 붙음. 범위 밖/비정수는 무시(기본 유지) |
| `window.padding-right` | 정수(0~256) | `8` | 위와 같되 **오른쪽** 여백 |
| `window.padding-bottom` | 정수(0~256) | `4` | 위와 같되 **아래** 여백 |
| `window.padding-left` | 정수(0~256) | `8` | 위와 같되 **왼쪽** 여백 |
| `window.padding-x` | 정수(0~256) | `8` | **left+right alias** — `padding-left`·`padding-right`를 같은 값으로 동시에 설정(대칭 좌우 여백). 개별 키와 혼용 시 파일에서 **나중에 나온 줄이 우선**(예: `padding-x=10` 다음 `padding-left=20` → left=20, right=10). 범위 밖/비정수는 무시(기본 유지) |
| `window.padding-y` | 정수(0~256) | `4` | **top+bottom alias** — `padding-top`·`padding-bottom`을 같은 값으로 동시에 설정(대칭 상하 여백). 우선순위 규칙은 `padding-x`와 동일(나중 줄 우선) |
| `window.opacity` | 실수(0.0~1.0) | `1.0` | 창 **배경 투명도**(0=완전 투명, 1=불투명). **default 배경**(빈 영역·기본 배경 셀)에만 적용 — 명시적 배경색 셀(ANSI bg·OSC 11 배경 set·선택 하이라이트)과 글자·커서는 불투명 유지(iTerm2/Ghostty `background-opacity` 모델). `1`보다 작으면 metal layer/창이 비불투명이 돼 뒤(데스크톱·다른 창)가 비친다. 범위 밖/비실수는 무시(기본 유지) |
| `render.frame-rate` | 정수(30~120) | `60` | macOS 앱 frame-loop timer cadence(Hz). 기본 60Hz가 현재 권장값이다: 30Hz보다 hover/scroll 최대 지연을 낮추면서 idle wakeup 비용은 보수적이다. 120Hz는 ProMotion/고주사율 화면에서 반응성을 우선할 때 쓰는 opt-in 상한이다. 현재 구현은 실제 모니터 주사율을 자동 감지하거나 vblank에 동기화하지 않는 `NSTimer` 기반이라, 60Hz 화면에서 120으로 올려도 표시 이득은 제한적이고 wakeup/전력 비용만 늘 수 있다. 진짜 적응형 주사율은 CVDisplayLink/CADisplayLink 기반 frame pacing 후속이다 |
| `window.blur` | 정수(0~100) | `0` | 창 **뒤(데스크톱)** 배경 블러 반경(px). `0`=끔. 양수면 그 반경으로 창 뒤를 흐리게 한다("프로스트 글래스"). **`window.opacity < 1`일 때만 유효** — 불투명 창은 뒤가 안 비쳐 블러도 안 보이므로 무시한다(Ghostty `background-blur`와 같은 게이트). 블러는 GPU 렌더러가 아니라 **OS/컴포지터 창 속성**이다(어느 OS도 Metal로 backdrop을 못 읽는다): macOS는 `CGSSetWindowBackgroundBlurRadius`(Ghostty·Terminal.app과 동일한 비공개 CGS API), Windows는 `DwmSetWindowAttribute`(추후), Linux는 `_KDE_NET_WM_BLUR_BEHIND_REGION`/kde-blur(추후·컴포지터 의존 best-effort)로 적용. 유효 반경 정책은 Zig 단일 출처, 실제 OS 호출만 platform host가 한다 |
| `window.background-image` | 문자열(파일 경로) | (없음) | 터미널 **배경 이미지** PNG 경로. 설정하면 그 PNG를 디코드해 창 전체를 덮는 배경으로 셀 **뒤**에 그린다(**aspect-fill** — 종횡비 유지 cover, 넘치는 축은 가운데 crop). **default 배경 셀**(빈 영역)이 투명이라 이미지가 비치고, 명시적 배경색 셀·글자·커서는 그 위에 그려진다(`window.opacity`와 같은 레이어 모델). **PNG 8-bit truecolor만**(maru 내장 디코더 — JPEG·8비트 외 PNG 등은 후속). 경로는 `~` 확장·상대경로 미지원(**절대경로** 권장). 못 읽거나 디코드 실패면 배경 없음(조용히 폴백) |
| `window.unfocused-dim` | 실수(0.0~1.0) | `0.0` | **비활성 split pane 디밍** — split이 여럿일 때 **활성이 아닌 pane**의 셀 색(전경·명시 배경·reverse)을 그 pane 배경색 쪽으로 이 비율만큼 보간해 흐리게 그려 활성 pane을 시각적으로 구분한다. `0`=끔(현행, 비활성 pane도 풀 밝기), `1`=완전히 배경색(글자 사라짐). 활성 pane은 항상 풀 밝기, split이 없으면(단일 pane) 무효. default 배경 셀(빈 영역)은 그대로(투명 유지). Ghostty `unfocused-split-opacity`(기본 0.7 불투명) 대응 — maru는 색공간 per-cell 보간, opt-in이라 기본 0.0. 범위 밖/비실수는 무시(기본 유지) |
| `split.divider-thickness` | 실수(0.0~16.0) | `1.0` | **split pane 경계선(divider) 두께**(논리 pt). `0`=divider를 안 그림(숨김). 렌더러가 이 pt를 device px로 환산(`× scale_milli/1000` — letter-spacing과 동형)해 divider strip 폭에만 쓴다. **폰트 크기와 무관한 고정 pt** — 옛 divider 동작(셀폭 ×15%)은 폰트를 키우면 비례해 굵어졌다. **커서 강조선**(bar/underline·hollow 외곽선, 셀 ~15%)과 `FocusOwner` border(`focus_accent`·theme border 두께)는 모두 이 값과 분리된다. 기본 `1.0`은 1x에서 1px·2x Retina에서 2px 헤어라인. 범위 밖/비실수는 무시(기본 유지) |
| `workspace.root` | 경로 | (없음) | 고정 시작 디렉터리(Ghostty `working-directory` 대응). 첫 창 + 상속이 꺼졌거나 상속할 cwd가 없을 때 폴백. 비어 있으면 maru cwd 상속(단 `/`면 `~`). `~`·`~/…`는 $HOME으로 확장. 아래 참조 |
| `workspace.tab-inherit-cwd` | `true`\|`false` | `true` | 새 워크스페이스 탭(`new_tab`)·새 Term(`new_term`)이 포커스 Term의 현재 cwd(OSC 7)를 상속할지. `false`면 `workspace.root`에서 연다(Ghostty `tab-inherit-working-directory`). 아래 참조 |
| `workspace.split-inherit-cwd` | `true`\|`false` | `true` | 새 분할(`split_*`, 팬)이 포커스 Term의 현재 cwd를 상속할지. `false`면 `workspace.root`에서 연다(Ghostty `split-inherit-working-directory`). 아래 참조 |
| `workspace.hold-on-startup-failure` | `true`\|`false` | `true` | 첫(유일) 셸이 시작 직후 **비정상 종료**해 usable 세션에 도달 못 하면 앱을 종료하지 않고 창을 유지(원인·복구 표시, ⏎로 재시작). 잘못된 `shell.command`/`shell.args`로 앱이 시작하자마자 꺼지던 것 방지. `false`면 기존처럼 종료(Terminal.app "shell 종료 시 닫기" 취향) |
| `session.keep-alive-after-quit` | `true`\|`false` | `false` | **영속 터미널 세션**(실험적 opt-in) — 정상 GUI Quit 뒤에도 일반 Window의 terminal runtime을 `maru-sessiond`가 유지하고 재실행 시 같은 `host_id:runtime_id`에 재접속한다([전체 P4 종료 gate](persistent-session-host.md#p4--일반-window-default-readinessbackground-알림)). **현재 기본 `false`**. 새 일반 Workspace/Term/split부터 토글 값을 적용하고 열린 Term은 process 사이로 이동하지 않는다. quick은 항상 in-process이고 Quit 때 종료된다. 현재 host 실패는 one-shot notice 뒤 local fallback하고 handle을 쓰지 않으며, P4 전에 persistent `not preserved` 상태를 추가한다. Workspace 설정에서 편집하고 모든 Window가 앱 전역 snapshot을 공유한다. 현재 global Reset은 값을 보존하지만 기본값과 같은 explicit `false`는 다시 쓰지 않고, row Reset도 generic override 제거를 따른다. release A G2가 global/row Reset 모두에서 값과 explicit override를 항상 보존하도록 바꾼 뒤에만 B로 진행한다. 사용자가 토글을 직접 바꿀 때만 true/false를 교체한다. 기본 전환은 release A가 default=false로 durable tombstone/provenance를 먼저 배포한 뒤 B에서 수행한다. B의 app-global bootstrap은 마지막 occurrence 기준으로 `missing|readable_absent`만 atomic explicit true 생성 성공 후 true, 실패 시 false+retryable notice로 처리한다. `explicit_valid`는 true/false 그대로, `explicit_invalid|unreadable|oversize`는 false·파일 무변경·persistent typed notice다. 여러 Window는 이 1회 결과 snapshot을 빌린다. B→frozen A rollback과 A runtime→B exact adapter attach를 자동 검증하며 A보다 오래된 downgrade는 지원하지 않는다. 외부 CLI(P5)와 자동 migration(U5) 전체는 선결이 아니고 나머지 조건은 링크된 P4 gate가 단일 출처다 |
| `scrollback.lines` | 정수(0~100000) | `1000` | 가시 화면 위로 보관할 과거 줄 수. `0`이면 스크롤백 비활성(과거 줄 안 보관). 범위 밖/비정수는 무시(기본 유지) |
| `file-panel.external-link-target` | `in-app`\|`system` | `in-app` | Markdown/HTML 파일 패널에서 사용자가 직접 누른 `http(s)` 링크의 기본 열기 대상. `in-app`은 현재 창의 새 browser 탭, `system`은 macOS 기본 브라우저로 연다. 어느 설정이든 `⌘⇧`+클릭은 이번 한 번만 시스템 브라우저를 강제한다. fragment는 현재 문서에 남고 로컬 `.md`/`.html` 링크는 파일 도크로 연다. |
| `scrollback.sticky-command` | 불리언 | `true` | sticky command — 스크롤백을 위로 올리면 지금 보이는 출력을 만든 **명령줄을 뷰포트 최상단에 고정** 표시(✓/✗ 종료상태 포함). OSC 133 semantic prompt 마커에 의존하므로 셸 통합(현재 zsh)이 켜진 세션에서만 동작하고, 마커가 없으면 그냥 안 뜬다. `false`면 끔 |
| `scroll.multiplier` | 실수(0.1~10.0) | `1.0` | 휠/트랙패드 **세로** 스크롤 속도 배수. `1.0`=OS 기본, `>1`=빠르게(예: `3`이면 한 틱에 3배 줄), `<1`=느리게. 가로(탭 바) 스크롤엔 적용 안 함. 배수는 maru 스크롤백뿐 아니라 **마우스 트래킹 앱(vim/tmux 등)에도 적용**된다(한 휠 틱이 더 많은 휠 이벤트로 전달 — Ghostty `mouse-scroll-multiplier`와 같은 동작). 범위 밖/비실수는 무시(기본 유지). `scrollback`(보관 줄 수)과 별개 |
| `bell.audible` | `true`\|`false` | `true` | BEL(0x07) 수신 시 시스템 소리(NSSound.beep)를 낼지. `false`면 음소거(코어 플래그는 정상 소비) |
| `bell.visual` | `true`\|`false` | `false` | BEL 수신 시 **화면을 잠깐 번쩍**이는 시각 벨. `true`면 활성 화면 위에 전경색 반투명 오버레이를 덮고 ~250ms 페이드아웃한다(소리를 못 듣는 환경 보조). `audible`과 독립이라 둘 다 켤 수 있다. 기본 `false`(현행 — 소리만) |
| `bell.dock-badge` | `true`\|`false` | `false` | BEL 수신 시 **창이 포커스 없을 때만** Dock 아이콘에 `●` 배지를 띄울지. `true`면 백그라운드에서 벨이 울리면 Dock에 배지가 뜨고 앱으로 돌아오면 사라진다(놓친 알림 표시 — Terminal.app/iTerm2 관례). 포커스 중이면 안 띄운다. 기본 `false` |
| `notifications.osc` | `true`\|`false` | `true` | 셸/TUI가 보낸 OSC 9(iTerm2)/777(rxvt) 데스크톱 알림을 띄울지. `false`면 OSC 알림을 무시한다(데스크톱 배너·인앱 알림 센터 둘 다). 세팅 GUI에서 `false`→`true`로 켜면 macOS 데스크톱 알림 권한 요청을 시도한다. 그 외 값은 무시 |
| `notifications.update-check` | `true`\|`false` | `true` | 새 버전이 나왔는지 앱 시작 시 1회 백그라운드로 확인해 인앱 알림으로 안내할지. 업그레이드를 자동 실행하지 않고 안내만 한다([배포·업데이트 전략](distribution.md)). 외부 요청(GitHub releases API)이라 끌 수 있다. 그 외 값은 무시 |
| `notifications.history-limit` | `8`~`512` | `64` | 인앱 알림 센터(종 아이콘 패널)에 보관할 최대 알림 수. 초과하면 가장 오래된 것부터 버린다. 범위 밖은 무시 |
| `text.ambiguous-width` | `narrow`\|`wide` | `narrow` | EAW Ambiguous 문자(동그란 번호 ① 등)의 셀 폭. 아래 참조 |
| `text.emoji-width` | `narrow`\|`wide` | `wide` | 이모지 표현(base+VS16·키캡 2️⃣ 등)의 셀 폭. 아래 참조 |
| `text.blink` | `true`\|`false` | `false` | SGR 5(blink) 글자를 실제로 깜빡일지. **기본 false** — 깜빡이는 콘텐츠는 접근성(WCAG 발작) 우려라 다수 터미널이 기본으로 끈다. 그 외 값은 무시 |
| `chrome.preset` | `minimal`\|`cutout`\|`capsule`\|`cell` | (없음) | chrome **레이아웃 프리셋** — 여러 chrome 축(`chrome.theme` 룩 + `chrome.tab-style` 탭)을 한 번에 고르는 큐레이션(`theme.preset`이 색에 쓰는 패턴 동형). `minimal`=rich+underline, `cutout`=rich+connected, `capsule`=rich+pill(Warp식), `cell`=TUI cell-grid 호환 경로다. **`chrome.preset` 전체는 세팅 UI와 검색에 행을 제공하지 않는다.** 기존 파일의 값은 TUI 제거·migration 결정 전까지만 읽어 적용하며 자동 변경하지 않는다. 개별 `chrome.theme`/`chrome.tab-style` 키를 **이 줄 뒤에** 두면 그 축만 override(순차, 나중 줄 우선). 색(`theme.preset`)과는 직교. 그 외 값은 무시 |
| `chrome.theme` | `tui`\|`rich` | `rich` | chrome(탭바·사이드바·divider·focus 테두리) 디자인 테마. `rich`(기본)=분리 색 팔레트(둥근 모서리·gradient)이며 새 Chrome component/UI는 이 경로만 확장한다. `tui`는 기존 config와 회귀 fixture를 위한 **읽기 호환 값**이다. **세팅 UI와 검색은 `chrome.theme`을 새로 선택·변경하는 행을 제공하지 않으며**, 기존 `tui` 줄도 자동 변경하지 않는다. 제거 시점에는 migration과 로더 정책을 별도 확정한다. 색 룩(theme.preset)과는 직교. 그 외 값은 무시. 자세히는 [Chrome 전략](chrome-strategy.md#chrome-전용-전환-정책) |
| `chrome.tab-style` | `connected`\|`underline`\|`pill` | `underline` | 활성 탭 룩(직교 축). `underline`(기본)=언더바만(미니멀, 배경 박스 없음), `connected`=터미널 본문색 cutout + 테마 accent 언더바(아래 본문과 이어짐), `pill`=lifted 회색으로 채운 둥근 캡슐 + 옅은 밝은 테두리(Warp식 떠 있는 pill, 포커스=fill 밝기). `chrome.theme`(tui\|rich)·`theme.preset`(색)과 직교. rich 경로에서만 의미(tui는 셀 밴드). 자세히는 [Chrome 전략 §7](chrome-strategy.md) |
| `input.page-keys` | `passthrough`\|`scroll` | `scroll` | 메인 화면 PageUp/Down 동작. 아래 참조 |
| `input.shift-enter` | `newline`\|`native` | `newline` | Shift+Enter 인코딩. `newline`(기본)=Option+Enter와 같은 `\x1b\r`(멀티라인 줄바꿈). 아래 참조 |
| `input.ime-enter` | `newline`\|`commit-only` | `newline` | IME(한글 등) 조합 중 Enter. `newline`(기본)=확정+개행 한 번에(브라우저 동작). 아래 참조 |
| `input.url-click-modifier` | `command`\|`control`\|`alt`\|`shift` | `command` | 터미널 안 URL을 **클릭으로 열 때** 눌러야 하는 수식키(macOS `command`=Cmd). 수식키 없는 클릭은 텍스트 선택이라 URL 열기는 수식키로 구분(iTerm2/Ghostty 관례). hover 시 URL 밑줄·링크 커서도 같은 키에서만 뜬다. 판정은 Zig 단일 출처. 그 외 값은 무시(기본 유지) |
| `input.mouse-hide-while-typing` | `true`\|`false` | `false` | **타이핑(글자 입력) 중 마우스 커서를 숨김**. `true`면 글자를 입력할 때 커서가 사라지고, 마우스를 움직이면 다시 보인다(macOS `NSCursor.setHiddenUntilMouseMoves` — 복원 자동). 단축키(탭 전환 등)·화살표·기능키는 안 숨긴다. 기본 `false`(현행 — 안 숨김). Ghostty `mouse-hide-while-typing` 대응 |
| `input.option-as-meta` | `true`\|`false` | `true` | macOS **Option 키를 Meta(Alt)로** 쓸지. `true`(기본, 현행)면 Option+글자가 ESC-prefix meta 인코딩(예: Option+b→`\x1bb`)이라 셸/readline의 Alt 단축키(Alt+B 단어 이동 등)·tmux Meta가 동작한다. `false`면 Option-단독 글자를 macOS 입력기에 맡겨 **특수문자를 조합**한다(US 레이아웃 Option+b→`∫`, Option+e→´ dead key). Cmd/Ctrl 동반 Option은 어느 쪽이든 단축키/인코딩 경로로 간다. 좌/우 Option 구분은 안 한다(device-independent). macOS/iTerm2 기본(조합)과 달리 maru는 현행 보존 위해 `true` 기본 — 특수문자 입력이 필요하면 `false`. Ghostty `macos-option-as-alt` 대응 |
| `input.right-click` | `paste`\|`menu`\|`reporting` | `paste` | **터미널 본문 우클릭** 동작(트래킹 앱이 마우스를 캡처하지 **않을** 때). `paste`(기본)=클립보드 즉시 붙여넣기(PuTTY/X11식), `menu`=복사/붙여넣기 컨텍스트 메뉴(macOS Terminal.app·iTerm2 관례), `reporting`=아무 동작 없음(이전 동작 — 리포팅만). **트래킹 앱(DECSET 1000~1003 — vim/tmux 등)이 켜져 있으면 이 값과 무관하게 마우스 리포팅이 우선**한다(이 설정은 비-리포팅 폴백). 사이드바·탭 바 우클릭은 그대로 Rename/Pin 메뉴. 그 외 값은 무시(기본 유지) |
| `input.word-separators` | 문자열 | (빈 값) | **더블클릭 단어 선택**의 추가 구분자 — 이 문자들도 단어 경계가 된다(공백은 항상 경계). 기본 빈 값(현행 — 공백만 경계라 비공백 run 전체를 선택). 예: `/:.@`를 넣으면 더블클릭이 경로·URL 컴포넌트를 잘게 선택하고, 구분자 위를 더블클릭하면 그 1글자만 선택한다. UTF-8 단일 codepoint들(예: `│`)도 가능. **URL hover/클릭 감지는 영향 없음**(`:`·`/`가 URL을 쪼개면 안 되므로 선택만 본다). Ghostty `selection-word-chars` 대응 |
| `input.paste-protection` | `true`\|`false` | `true` | **붙여넣기 보호** — 개행(`\n`/`\r`)이나 bracketed paste 종료 마커(`ESC[201~` 인젝션)가 포함된 붙여넣기를 바로 PTY로 보내지 않고 **확인 모달**을 띄운다. 웹/문서에서 몰래 명령이 딸려온 클립보드가 붙여넣는 순간 실행되는 "copy/paste 공격"을 막는다. `false`면 확인 없이 즉시 붙여넣는다(개행이 있으면 셸에서 바로 실행될 수 있음). bracketed paste(DECSET 2004)를 켠 프로그램에서의 동작은 `input.bracketed-paste-is-safe`가 가른다. 확인 모달에서 [붙여넣기]를 고르면 그대로 진행, [취소]면 버린다. 위험 제어 바이트(NUL·BS·ESC·Ctrl+C 등) 제거는 이 설정과 무관하게 항상 적용된다(xterm/Ghostty 관례). 베이스: Ghostty `clipboard-paste-protection`. 범위 밖/비-bool은 무시(기본 유지). 단일 출처: [터미널 호환성/보안 정책](terminal-compatibility-policy.md) "Bracketed Paste" |
| `input.bracketed-paste-is-safe` | `true`\|`false` | `true` | **bracketed paste를 안전으로 볼지**. 실행 중 프로그램이 bracketed paste(DECSET 2004)를 켰으면(zsh/bash 등 대부분의 대화형 셸) 붙여넣기가 `ESC[200~`…`ESC[201~`로 감싸져 자동 실행되지 않으므로, `input.paste-protection`이 켜져 있어도 **확인을 생략**한다(평소 붙여넣기가 안 귀찮음). `false`면 bracketed paste도 개행 검사를 거쳐 확인한다. 어느 값이든 본문에 종료 마커(`ESC[201~`)가 섞이면 bracketed여도 **항상** 확인한다(괄호 조기 종료 인젝션은 신뢰하지 않음). 베이스: Ghostty `clipboard-paste-bracketed-safe`. 범위 밖/비-bool은 무시(기본 유지) |
| `input.link-detection` | `osc8-only`\|`web`\|`full` | `full` | 화면 텍스트의 **링크(URL·파일 경로) 자동 감지 범위**. `full`(기본)=추가 스킴(`file://`·`mailto:`·`ssh:` 등)과 절대(`/`)·홈(`~/`)·상대(`./` `../`)·bare(`src/foo.zig`) 경로까지 (config 수식키)+클릭으로 연다 — 클릭 시 파일 **존재를 확인**해 오탐을 막고(상대·bare는 OSC 7 cwd 기준 resolve), 종류에 따라 파일은 `URL(fileURLWithPath:)`·웹은 `URL(string:)`로 macOS가 연다. `web`=http(s)만(이전 동작). `osc8-only`=자동 감지 끔(프로그램이 OSC 8로 명시한 하이퍼링크만). OSC 8 명시 링크는 이 값과 무관하게 항상 동작한다. `:line:col` 접미는 인식하되 1차는 파일만 연다(에디터 줄 점프는 후속). 자세히는 [링크 감지](link-detection.md) |
| `input.link-open-target` | `auto`\|`in-app`\|`system` | `auto` | 터미널에서 연 **웹 링크(http/https)를 어디에 띄울지**. `auto`(기본)=현재 워크스페이스 탭에 **보이는 브라우저 패널**(`⌘⌥T`로 연 browser 탭)이 있으면 그 패널에서 열고, 없으면 시스템 기본 브라우저 — 브라우저를 안 쓰면 동작이 이전과 같다(회귀 없음). `in-app`=항상 인앱: 보이는 패널이 있으면 재사용하고 **없으면 새 browser 탭을 열어** 그곳에 띄운다. `system`=항상 시스템 기본 브라우저(이전 동작). 대상은 http(s) 리터럴만 — 파일 경로 링크와 `mailto:`·`ssh://` 같은 비-HTTP 스킴은 이 값과 무관하게 기본 앱으로 연다. 파일 패널(Markdown/HTML) **문서 안의** 링크는 별도 설정 `file-panel.external-link-target`이 정한다(그쪽 `in-app`은 재사용 없이 늘 새 탭 — 문맥이 달라 분리). 자세히는 [링크 감지](link-detection.md) |
| `input.selection-clear-on-typing` | `true`\|`false` | `true` | **타이핑하면 터미널 텍스트 선택(하이라이트)을 해제**할지. `true`(기본)면 그 pane에 글자를 입력하는 순간 남아 있던 선택이 사라진다. `Esc`는 이 값과 무관하게 **항상** 해제한다("선택 취소"의 관용 키). `false`면 선택이 그대로 남는다 — 다만 그 경우 `⌘A`(전체 선택)로 만든 하이라이트는 다시 선택하거나 창 크기를 바꾸기 전까지 남는다. 타이핑 외에 **마우스 리포팅 중인 pane**(vim·tmux·Claude Code 등 DECSET 1000~1003을 켠 TUI)의 클릭·휠은 이 값과 무관하게 항상 해제한다 — 그 pane의 마우스는 앱이 소유하므로 선택을 지울 다른 방법이 없다. 베이스: Ghostty `selection-clear-on-typing`(기본 `true`). 그 외 값은 무시(기본 유지) |
| `osc52.read` | `deny`\|`allow` | `deny` | **OSC 52 클립보드 읽기**(`OSC 52 ; <Pc> ; ? ST` 쿼리) 정책. `deny`(기본)=응답하지 않음 — 원격/내부 프로그램이 로컬 클립보드를 **탈취하지 못하게** 한다(보안). `allow`=시스템 클립보드를 base64로 인코딩해 `OSC 52 ; <Pc> ; <base64> ST`로 프로그램(PTY)에 응답한다. 쓰기(OSC 52 set)는 별개로 기본 허용이다(이 설정은 읽기 전용). 클립보드가 16MB 초과면 응답하지 않음(폭주 방어). 그 외 값은 무시(기본 유지) |
| `keyhint.enabled` | `true`\|`false` | `true` | **단축키 힌트 HUD** — 모디파이어를 일정 시간 홀드하면 활성 pane(포커스된 패널) 우상단에 현재 바인딩된 단축키를 카테고리별 키캡으로 보여 준다. `false`면 홀드 감지 자체를 끈다. macOS Cmd 단독 홀드는 OS 충돌이 없어 기본 켬. 단축키가 적용되는 패널에 시각적으로 묶인다(`docs/keybind-hints.md`) |
| `keyhint.delay` | 숫자(0~5000) | `400` | 힌트 표시까지 모디파이어를 누르고 있어야 하는 시간(ms). 짧으면 빠른 `Cmd+T`에도 깜빡이고, 길면 반응이 굼뜨다. 다른 키를 누르면(=실제 단축키 실행) 표시 전이라도 취소된다. 범위 밖은 무시(기본 유지) |
| `keyhint.modifier` | `command`\|`control`\|`option` | `command` | 힌트를 띄우는 트리거 모디파이어(이 키 **단독 홀드**). 기본 `command`(⌘). 그 외 값은 무시(기본 유지) |
| `quick-terminal.height` | 숫자(0.1~1.0) | `0.45` | 가장자리에 수직인 '두께' 비율(화면 대비). `top`/`bottom`=높이, `left`/`right`=폭, `center`=세로 비율. 범위 밖/비숫자는 무시 |
| `quick-terminal.width` | 숫자(0~1.0) | `0`(=`height` 따라감) | **`center` 전용** 가로 비율(화면 대비). 기본 `0`은 **sentinel**로 `height`와 같게(정사각) — `0`을 직렬화→재파싱해도 diagnostic이 안 나게 range 하한을 `0`으로 둔다(`height`는 sentinel이 없어 `0.1~1.0`). `0`보다 크면 그 비율(아주 좁은 `0<x<0.1`도 forgiving 허용). `top`/`bottom`(전폭)·`left`/`right`(`height`로 두께)에선 무시. 범위 밖/비숫자는 무시 |
| `quick-terminal.auto-hide` | `true`\|`false` | `true` | 포커스 잃으면(다른 창/앱 클릭) 자동 숨김. `false`면 토글로만 |
| `quick-terminal.screen` | `main`\|`mouse` | `main` | 어느 화면에 띄울지(`mouse`=마우스가 있는 화면). 그 외 값은 무시 |
| `quick-terminal.position` | `top`\|`bottom`\|`left`\|`right`\|`center` | `top` | 어느 가장자리에서 슬라이드해 나올지. `center`=화면 중앙(세로=`height`·가로=`width`, 슬라이드 대신 페이드 인). 그 외 값은 무시 |
| `quick-terminal.chrome` | `full`\|`minimal` | `full` | 패널 chrome 수준. `minimal`=세로 사이드바·pane 탭 바 없이 터미널 그리드만(드롭다운 스크래치 터미널 모습). `full`=메인 창처럼 다 보임. 그 외 값은 무시. 메인 창엔 영향 없음(quick terminal 전용) |
| `quick-terminal.minimal-tabs` | `true`\|`false` | `false` | `chrome=minimal`일 때 탭(워크스페이스·pane Term) 생성 허용 여부. `false`(기본)=단일 스크래치 — `⌘T`/`⌘⇧T` 무동작(사이드바·탭 바가 없어 안 보이는 탭 생성을 막음; split `⌘D`은 divider로 보이므로 유지). `true`=탭 허용(`⌘1..9`/`⌘]`로 전환). 탭이 2개 이상이면 **우상단에 작은 탭 점 인디케이터**가 떠 활성 탭을 보여준다(워크스페이스가 여러 개면 워크스페이스, 아니면 활성 pane의 Term). `chrome=full`이면 이 값과 무관하게 탭이 항상 동작. 그 외 값은 무시 |
| `status-bar.show` | `true`\|`false` | `true` | 창 하단 **상태표시줄** 표시 여부. 바는 창 높이를 실제로 먹으므로 끄면 그만큼 터미널 행·도크·사이드바 뷰포트가 되돌아온다([상태표시줄](status-bar.md)). quick terminal은 이 값과 무관하게 항상 안 뜬다(chrome을 걷어낸 모드). 적용은 다음 프레임부터 — 재시작 불필요 |
| `sidebar.show-branch` | `true`\|`false` | `true` | 세로 사이드바 세션 카드에 git 브랜치명을 표시할지. 카드 이름줄은 식별용이라 항상 표시. 그 외 값은 무시. 사이드바 헤더 **view options(⚙) 메뉴**에서 토글하면 이 키에 양방향 반영(앱→config 파일 atomic write, 주석 보존) |
| `sidebar.show-folder` | `true`\|`false` | `true` | 위와 같되 폴더(cwd) 경로 줄(cwd가 git repo 안일 때만). 마찬가지로 view options(⚙) 메뉴에서 토글·양방향 |
| `sidebar.agent-transcript-hook` | `true`\|`false` | `true` | 에이전트 행의 **마지막 대화**를 항상 채우기 위해 claude 상태줄 훅을 설치한다. 끄면 에이전트가 자식에게 내려주는 세션 신원만 쓰므로, 도구를 한 번도 실행하지 않는 세션은 대화 줄이 빈다. 설치물(claude 설정 디렉터리 = `$CLAUDE_CONFIG_DIR` 또는 `~/.claude`의 `maru-statusline.sh`·`.maru-statusline-installed`와 `settings.json`의 `statusLine`)은 이름으로 Maru 것임이 드러나고, 끄면 그것만 제거한다. 감쌌던 원래 명령은 **마커 파일이 단일 출처**라 스크립트를 잃어도 되살아난다. **그 디렉터리가 없으면(claude 미설치) 아무것도 만들지 않는다.** `settings.json`은 `statusLine` 키만 바꾸고 `hooks`를 포함한 나머지는 그대로 두며, 쓰던 상태줄 명령은 지우지 않고 감싼다. 화면에는 아무것도 출력하지 않아 claude 상태줄 모양은 그대로다. codex는 해당 없음(외부 스크립트를 실행하는 상태줄 설정이 없다) |
| `sidebar.width` | 정수(120~480) | `180` | 세로 사이드바 폭(논리 pt, DPI 스케일). 사이드바 우측 경계를 드래그하면 이 키에 양방향 반영(드래그 종료 시 앱→config 파일 atomic write, 주석 보존). 범위 밖/비정수는 무시(기본 유지). 런타임은 헤더 아이콘(신호등·⚙ 등)이 겹치지 않게 폰트 크기에 비례한 **동적 하한**으로 다시 끌어올릴 수 있어, 작은 값을 저장해도 실제 폭은 그 하한 이상이 된다 |
| `term` | 문자열 | `xterm-maru` | 셸에 줄 `$TERM`(컴파일 실패 시 `xterm-256color` 폴백). 아래 참조 |
| `shell-integration.ssh` | `true`\|`false` | `false` | 평범한 `ssh`를 `maru ssh`로 라우팅해 원격에 `xterm-maru` terminfo를 전파할지(opt-in). 기본 off(다운그레이드로 원격 안 깨짐). 아래 [셸 통합 ssh 라우팅](#셸-통합-ssh-라우팅-shell-integrationssh) 참조 |
| `env.<KEY>` | 문자열 | (없음) | 새 셸에 주입할 환경변수(`env.EDITOR = nvim`처럼 여러 줄). 부모 상속 env + maru override(TERM 등) **위에 upsert** — 같은 KEY면 덮어쓰고 없으면 추가("부모 + 사용자"). 단 control-plane selector `MARU_PANE_ID`는 spawn 값이 최종 우선한다. 값은 양끝만 trim(내부 공백 보존), 빈 값 허용. 빈 KEY(`env. =`)는 무시. 새로 여는 셸에만 적용(reload는 기존 셸 env 안 바꿈). 아래 참조 |
| `shell.command` | 경로 | (없음) | 대화형 셸 실행 파일 경로(절대경로). 비어 있으면(기본) `$MARU_INTERACTIVE_SHELL`→`$SHELL`→`/bin/sh` 순으로 자동 결정(현행). 새로 여는 셸에만 적용. 아래 참조 |
| `shell.args` | 문자열 | `-i` | 셸 인자(argv, command 제외). 공백으로 토큰 분리(`shell.args = -i -l`). 따옴표 미지원. 빈 값(`shell.args =`)이면 인자 없음. 아래 참조 |
| `keybind` | `<조합> = <action>` | (없음) | 여러 줄 가능. 아래 참조 |

### 컬러 테마 프리셋 (`theme.preset`)

한 줄로 색 세트의 **base**를 고른다. 프리셋이 배경/전경/커서/선택과 ANSI 16색 팔레트를 한 번에 채우고,
그 뒤에 오는 개별 `theme.*` 키가 일부만 덮어쓴다(loader 순차 적용 — 나중 줄 우선). **프리셋 줄을 개별 색
키보다 위에 두라** — 프리셋이 개별 색 키보다 뒤에 오면 앞 설정을 리셋한다(Ghostty `theme` 시맨틱과 동일).

사용 가능한 프리셋:

| 값 | 설명 | 배경 |
|---|---|---|
| `maru` (기본) | Maru 기본 테마(무채색 다크, ANSI 16색은 xterm 표준) | `#101010` |
| `ghostty` | Ghostty 기본 테마(청회색 다크) | `#282c34` |
| `gruvbox-dark` | Gruvbox Dark(웜 레트로 — 갈색·주황·올리브) | `#282828` |
| `solarized-dark` | Solarized Dark(청록 다크) | `#002b36` |
| `solarized-light` | Solarized Light(**라이트** — 베이지) | `#fdf6e3` |
| `dracula` | Dracula(보라·핑크 다크) | `#282a36` |
| `catppuccin-mocha` | Catppuccin Mocha(파스텔 다크) | `#1e1e2e` |
| `catppuccin-latte` | Catppuccin Latte(**라이트** — 파스텔) | `#eff1f5` |
| `light-pink` | Light Pink(**라이트** — 로즈·골드·틸 핑크) | `#f5f5f5` |
| `dark-pink` | Dark Pink(**다크** — 로즈·핑크·라벤더, 고스티 배경) | `#282c34` |
| `rose-pine` | Rosé Pine(뮤트한 로즈·파인 다크) | `#191724` |
| `rose-pine-dawn` | Rosé Pine Dawn(**라이트** — 크림) | `#faf4ed` |
| `tokyo-night` | Tokyo Night(블루·퍼플 네온 다크) | `#1a1b26` |
| `nord` | Nord(아틱 블루그레이 다크) | `#2e3440` |
| `one-dark` | Atom One Dark(Atom 아이코닉 다크) | `#21252b` |
| `one-light` | Atom One Light(**라이트**) | `#f9f9f9` |

> **베이스/결정**: `maru`는 Maru 기본값. `ghostty`는 Ghostty 기본값(배경/전경은 Ghostty `Config.zig`, ANSI 16색은
> `terminal/color.zig`의 기본 팔레트)을 베이스로 하되, Ghostty가 정의하지 않는 `cursor`/`selection`은 Maru 기본을 쓴다.
> 나머지(`gruvbox-dark`·`solarized-*`·`dracula`·`catppuccin-*`·`rose-pine`·`rose-pine-dawn`·`tokyo-night`·`nord`·`one-dark`·
> `one-light`)는 **iTerm2-Color-Schemes**의 표준 색 값(배경/전경/커서/선택/팔레트)을 그대로 가져왔다 — 색 **값만** 인용했고
> 코드 표현은 옮기지 않았다(clean-room). 정확한 팔레트 16색은 `src/config/theme.zig`의 프리셋 상수가 단일 출처다.
> `light-pink`·`dark-pink`만 예외로 mgwg **light-pink-theme**(VS Code)의 라이트/다크 두 변형에서 배경/전경/커서/선택 값을
> 가져오되, 이 테마가 **터미널 ANSI 색을 정의하지 않으므로** ANSI 16색은 테마의 **구문 색**(`light-pink`: 키워드 로즈·숫자
> 골드·문자열 틸·타입 퍼플 / `dark-pink`: invalid 핫핑크·브래킷 하이라이트의 골드·블루·퍼플·틸 + tag/storage 시그니처 핑크)에서
> 의미 매핑으로 파생했다(역시 색 의도만 — clean-room). 라이트인 `light-pink`는 `catppuccin-latte`처럼 black↔white를 반전해
> 본문 가독성을 지킨다. 다크인 `dark-pink`는 VS Code 원본이 *default dark*(`#1e1e1e`/`#d4d4d4`)라 그대로 옮기면 회색으로만
> 보여 핑크가 안 드러나므로, **배경·사이드바·탭 영역은 고스티와 동일한 중립 톤**(배경 `#282c34` = 고스티 실제 배경, 사이드바는
> 그 배경에서 파생 `#40444c` — 사용자 요청)으로 두고, 핑크 정체성은 전경(`#ecdce4` 로즈-화이트)·커서·탭 accent(`#f4a8c9` 파스텔
> 핑크 — 커서·언더바·활성 카드 좌측 막대 통일)와 **활성 카드**가 담당한다. 활성 카드 fill(`sidebar_active #644655`)은 파스텔로
> 밝히지 않고 **더스티 다크 로즈**로 둔다 — `sidebar_active`는 카드뿐 아니라 컨텍스트 메뉴·알림 선택행·탭 밴드 배경으로도 쓰이고
> 그 위 글자가 모두 밝은 `sidebar_foreground`라 카드만 밝히면 그 밝은 글자들이 묻히므로(밝은 글자 읽히는 어둡기 유지, 채도만
> 낮춰 순화). 검색 매치색만 Maru 다크 앰버를 유지해 대비되게 한다.
>
> - **검색 매치색**(스크롤백 Find 하이라이트)은 Maru 고유라 **다크 프리셋**에선 Maru 기본(다크 앰버)을 유지한다. **예외:
>   라이트 프리셋**(`light-pink`·`rose-pine-dawn`·`one-light`)은 라이트 배경에서 다크 앰버가 안 보여 테마의 따뜻한 골드/피치
>   톤으로 검색 매치색을 덮는다(`solarized-light`·`catppuccin-latte`는 이 정책 도입 전이라 Maru 기본 유지).
> - **accent 색**(chrome `accent_bar` 역할 — 활성 탭/포커스 pane 하단 언더바, 사이드바 활성 카드 좌측 막대, 세팅 UI 강조)은
>   **프리셋마다 시그니처 색**을 준다: 예전엔 Maru 브랜드 앰버(`#dda15e`)로 테마와 무관하게 고정이었으나, 이제 `theme.accent`가
>   테마-구동이라 탭 언더바 색이 프리셋별로 달라진다(예: `dark-pink`=파스텔 핑크 `#f4a8c9`, `gruvbox-dark`=오렌지 `#fe8019`,
>   `nord`=frost `#88c0d0`, `dracula`=퍼플 `#bd93f9`). `maru`·프리셋 없는 사용자 지정 테마는 브랜드 앰버로 폴백한다.
> - **라이트 테마**(`solarized-light`·`catppuccin-latte`·`light-pink`·`rose-pine-dawn`·`one-light`)는 사이드바 색을 명시한다 —
>   사이드바 기본 파생은 배경을 *밝게* 하는데, 라이트 배경에선 거의 흰색이 돼 구분이 사라지므로 배경보다 *어두운*(또는 더
>   짙은 톤) 표면색을 직접 준다.
> - **선택색 가독성**: Maru는 선택 글자색을 안 바꾸고 배경만 칠하므로, 스킴 원값이 **밝은색**(`catppuccin-*`의 rosewater,
>   `nord`의 snow-storm `#eceff4`)이면 밝은 글자가 묻힌다 — 어두운/중간 표면색(`nord`는 polar night `#434c5e`)으로 바꾼다.
>   `one-light`의 커서도 스킴 원값(`#bbbbbb`)이 라이트 배경에서 안 보여 foreground(진한 잉크)로 둔다.
> - **팔레트·프로그램 색 대비 자동 보정**: 위 라이트 프리셋(과 `theme.palette`·프리셋 없이 배경만 밝힌 xterm 기본색)은
>   **업스트림 표준값을 그대로 보존**하는 게 원칙이라, 일부 색(밝은 노랑·초록·흰색 등)은 라이트 배경에서 대비가 약해
>   안 읽힐 수 있다. 프로그램이 escape로 직접 고르는 256색·truecolor(다크 전용 배색을 하드코딩한 TUI·에이전트 CLI 등)도
>   마찬가지다. 이를 런타임에 읽히게 하는 안전장치가 [`theme.min-contrast`](#키)(기본 `3.0`)다 — 전경이 배경
>   대비 그 명암비에 못 미치면 색상을 보존한 채 최소한만 보정한다(밝은 배경=어둡게, 어두운 배경=밝게). **프리셋 상수(파일의 원색 세트)는 손대지 않고
>   렌더 시점 해석에서만 하한을 적용**하므로 "스킴 표준값 보존"과 "가독성"이 양립한다(특히 `one-light`의 안 보이는
>   bright-white `#ffffff`·밝은 yellow처럼 업스트림 자체가 저대비인 경우를 교정). `0`으로 끄면 업스트림 원색 그대로다.
>   **팔레트 선보정**(ANSI 16색)은 어둡게만 하므로 다크 프리셋에선 무동작이다(그 팔레트가 ANSI 배경색·OSC 4 응답으로도
>   나가기 때문 — 밝히면 배경이 뜬다). 다크 배경에서 안 보이는 **전경**(라이트 전용 배색을 truecolor로 하드코딩한
>   프로그램)은 렌더 per-cell 하한이 밝히는 방향으로 교정한다 — 단 번들 테마 팔레트·powerline·faint를 건드리지 않도록
>   **좁게** 적용한다(조건은 위 키 표).
>
> 색 룩만 정하며, chrome **디자인 룩**(`chrome.theme` = tui|rich)과는 직교다.

### PageUp/PageDown (`input.page-keys`)

메인 화면(셸 프롬프트)에서 PageUp/PageDown를 어떻게 다룰지 정한다. **alt 화면(vim·less 등)에선
어느 값이든 항상 `\e[5~`/`\e[6~`를 앱으로 보내** 앱이 자체 페이징한다.

- `scroll` (기본): Terminal.app/iTerm2처럼 메인 화면에서 Maru 스크롤백을 한 페이지씩 스크롤한다.
  셸로 `\e[5~`를 보내지 않아 **셸 keymap(vi/emacs)·프레임워크와 무관하게 입력줄이 안 깨진다** —
  Mac 관례이자 가장 견고하다. 메인 화면 앱(드물게 PageUp을 쓰는 TUI)에는 키가 전달되지 않는다.
- `passthrough` (opt-in): xterm/Ghostty처럼 메인 화면에서도 `\e[5~`/`\e[6~`를 PTY로 보낸다.
  레퍼런스와 일치하지만 셸 프롬프트에서 깨진다 — emacs keymap은 BEL+`~`를 입력줄에 박고, **vi
  keymap은 끝 `~`를 vi-swap-case로 해석해 대소문자를 토글한다**(실측 확인). xterm 순정이 필요할 때만.

> `Shift+PageUp`/`Shift+PageDown`은 이 설정과 무관하게 항상 스크롤백을 스크롤한다.

### Ambiguous 문자 폭 (`text.ambiguous-width`)

동그란 번호(① ② ③ U+2460~U+24FF) 같은 **East Asian Width "Ambiguous"** 문자가 한 칸을 차지할지(narrow)
두 칸을 차지할지(wide)를 정한다. 이 문자들은 문맥에 따라 폭이 갈리는데, 폰트는 보통 전각(~2칸)으로 그린다.

- `narrow` (기본): 한 칸(advance 1). **UAX #11 §5 권고**("문맥을 신뢰성 있게 정할 수 없으면 narrow로")와
  Ghostty·xterm.js가 모두 따르는 기본값이다. 그 문자를 1칸으로 가정하는 프로그램(셸 readline·대부분의 TUI)과
  커서·정렬이 안 깨진다. 폰트가 전각으로 그려 1칸에 안 맞을 때는 **다음 셀이 비어 있으면 렌더만 2칸으로** 키워
  온전히 보여주고(advance는 1 유지 — Ghostty `constraintWidth`와 동일), 다음 셀이 차 있으면 1칸에 맞춰 축소한다.
- `wide` (opt-in): 두 칸(advance 2). plain 출력에서 동그란 번호를 전각 크기로 깔끔하게 보고 싶거나, **CJK 로캘처럼
  프로그램도 그 문자를 2칸으로 가정하는 환경**에 맞춘다. 단 1칸을 가정하는 프로그램(셸 줄 편집·일부 TUI 박스/표)과는
  **커서·정렬이 1칸씩 어긋날 수 있다** — 폭은 maru와 프로그램의 공유 약속이라 한쪽만 바꾸면 틀어지기 때문이다.

적용 범위는 동그란/괄호친 영숫자(Enclosed Alphanumerics U+2460~U+24FF)다. **box/block(─ █)·Powerline·Nerd Font
아이콘(PUA)** 은 maru가 합성하거나 1칸으로 그리므로 `wide`여도 폭이 안 바뀐다(레이아웃 보존). 잘못된 값은 무시(기본 유지).

> 베이스/결정: 기본 `narrow`는 Ghostty·xterm.js·UAX #11과 일치한다. `wide`는 iTerm2 등이 가진 "ambiguous를 wide로"
> 옵션과 같은 트레이드오프(표시 깔끔 ↔ 1칸 가정 프로그램과의 정렬)를 사용자가 고르게 한 것이다.

### 이모지 폭 (`text.emoji-width`)

VS16(U+FE0F)으로 이모지 표현이 된 글자(❤️ = ❤+VS16)와 **키캡**(2️⃣ = `2`+VS16+U+20E3) 같은 이모지 표현 클러스터가
한 칸(narrow)을 차지할지 두 칸(wide)을 차지할지를 정한다. 이런 클러스터는 base가 텍스트 글자(폭 1)라, 폭을 안 키우면
컬러 이모지가 **1칸에 욱여넣어져 작게** 나온다.

- `wide` (기본): 두 칸(advance 2). Ghostty·iTerm2·kitty, 그리고 **모던 TUI가 쓰는 string-width 라이브러리**가
  이모지(키캡 포함)를 2칸으로 세므로, maru도 2칸으로 맞춘다 — 이모지가 풀사이즈로 또렷하게 나오고, 2칸을 예약하는
  TUI(예: Claude Code) 레이아웃과도 정합한다(1칸만 그리면 작은 이모지 + 옆 빈틈이 생긴다).
- `narrow` (opt-in): 한 칸(advance 1, EAW 그대로). **zsh ZLE 등이 base+VS16을 1칸으로 가정**하는 환경에서 셸 줄
  편집(커서·재출력)이 어긋나는 게 더 거슬릴 때 끈다. 이모지는 작게 나오지만 1칸 가정 프로그램과 정렬이 보존된다.

`grapheme cluster mode`(DECSET 2027)를 켜는 앱과는 이 설정과 무관하게 항상 2칸이다(앱이 너비를 합의한 상태).
적용 대상은 VS16 이모지 표현과 키캡이며, 스킨톤·국기(지역 표시자 페어)는 mode 2027에서만 한 글자로 묶는다(별도 동작).

> 베이스/결정: 기본 `wide`는 Ghostty·iTerm2·kitty 및 모던 TUI의 사실상 표준(이모지=2칸)과 일치시켜, 키캡/VS16 이모지가
> 작게 나오던 것을 푼다. `narrow`는 1칸을 가정하는 셸 줄 편집과의 정렬을 우선하려는 opt-out이다(`ambiguous-width`와 같은
> 트레이드오프 구조 — 표시 정확 ↔ 1칸 가정 프로그램과의 정렬).

### Shift+Enter (`input.shift-enter`)

Shift+Enter를 어떻게 인코딩할지 정한다. macOS 터미널의 키 인코딩은 Shift를 Enter에 반영하지 않아, 기본 동작이면
Shift+Enter가 일반 Enter와 똑같은 `\r` 한 바이트를 보낸다 — 그래서 셸/CLI가 둘을 **구분하지 못해** 줄바꿈이 아니라
명령 실행이 된다. Option(Alt)+Enter는 `\x1b\r`(ESC+CR)이라 앱이 별도 키로 인식해 멀티라인 줄바꿈으로 처리한다.

- `newline` (기본): Shift+Enter를 **Option+Enter와 같은 바이트**로 보낸다 — kitty 키보드 프로토콜이 꺼진 일반
  셸에선 `\x1b\r`(ESC+CR), 켜진 앱에선 `\x1b[13;3u`(Alt+Enter via CSI u). 어느 쪽이든 Option+Enter와 **항상 같은**
  시퀀스라(내부적으로 Meta 수정자로 바꿔 인코딩한다), Claude Code 등 CLI/TUI가 줄바꿈(전송 없이 다음 줄)으로
  인식한다 — 모던 에디터/브라우저의 Shift+Enter 기대치와 일치한다.
- `native` (opt-out): Shift를 인코딩에 반영하지 않는 기존 터미널 동작. 일반 셸에선 `\r`(일반 Enter와 동일),
  kitty 키보드 프로토콜이 켜진 앱에선 `\x1b[13;2u`(CSI u). xterm/Ghostty 순정 동작이 필요할 때만.

> Shift는 chord modifier가 아니라 IME 키 트랜잭션을 거쳐 들어오므로, 이 변환은 **모달(Find의 Shift+Enter=이전
> 매치 등)이 키를 소비하지 않고 PTY로 내려보내는 경우**에만 적용된다. IME 조합 중 Shift+Enter도 같은 규칙을 따른다.

> 변환은 keybind 해석 **앞에서** 일어난다(Shift+Enter를 Option+Enter로 바꾼 뒤 resolver가 본다). 그래서
> `keybind = Opt+Enter = <action>`을 두면 Shift+Enter도 그 action을 발동하고, `keybind = Shift+Enter = <action>`은
> `newline`에선 닿지 않는다(변환이 먼저 적용됨). Shift+Enter에 직접 바인딩을 걸려면 `native`로 둔다.

### IME 조합 중 Enter (`input.ime-enter`)

한글 등 IME 조합 중에 Enter를 눌렀을 때의 동작이다. macOS 입력기는 이 Enter를 **조합 확정**에만 쓰고 개행은
소비하므로(Terminal.app/Ghostty 기본), 기본 동작이면 Enter를 한 번 더 눌러야 줄바꿈/실행이 된다. 웹 브라우저의
터미널은 확정과 개행을 한 번에 처리한다 — 그 동작을 기본값으로 둔다.

- `newline` (기본): 조합을 확정하면서 그 Enter의 **개행도 함께 보낸다**(엔터 한 번에 확정+실행 — 브라우저 동작).
  확정 텍스트 전송 뒤 Enter를 replay하며, 입력기가 Enter를 이미 소비했으므로 중복 개행은 생기지 않는다.
- `commit-only` (opt-out): 조합만 확정하고 개행은 보내지 않는다(macOS 네이티브 입력기 기본). 확정 후 Enter를
  한 번 더 눌러야 개행된다.

> `input.shift-enter`와 직교한다 — IME 조합 중 Shift+Enter를 확정하면, replay되는 Enter가 `input.shift-enter`
> 규칙대로 인코딩된다(`newline`이면 `\x1b\r`).

### 시작 디렉터리 (`workspace.*`)

새로 여는 셸이 어느 디렉터리에서 시작할지 정한다. **Ghostty의 `working-directory` +
`*-inherit-working-directory` 모델**을 그대로 따른다 — 고정 시작 경로 하나(`workspace.root`)에, surface
종류별 cwd 상속 토글(기본 켜짐)을 둔다.

**기본 동작(설정 없음)**: 새 워크스페이스 탭·새 Term·분할 모두 **직전 포커스 Term의 현재 cwd(OSC 7)를
상속**한다. 즉 `cd`로 옮긴 디렉터리에서 ⌘T/⌘⇧T/⌘D를 누르면 그 위치에서 새 셸이 시작한다(tmux·iTerm2·Ghostty
기본과 동일). 셸 통합이 없거나 첫 프롬프트 전이면 상속할 cwd가 없어 `workspace.root`로 폴백한다.

```conf
# 고정 시작 경로(Ghostty working-directory). 첫 창 + 상속이 꺼졌거나 상속할 cwd가 없을 때 쓴다.
workspace.root = ~/projects

# 상속 토글(기본 둘 다 true = 포커스 cwd 상속). false면 그 종류는 항상 root에서 연다.
workspace.tab-inherit-cwd   = true   # 새 워크스페이스 탭(⌘⇧T) + 새 Term(⌘T)
workspace.split-inherit-cwd = true   # 새 분할(⌘D, 팬)

```

- **`workspace.root`** — 고정 시작 디렉터리. **절대경로 또는 `~`/`~/…`만** 받는다 — 상대경로나 `~user`(다른
  사용자)는 설정 로드 시 무시하고 진단을 남긴다(다른 키처럼 forgiving — 잘못된 값이 조용히 무동작하지 않게).
  `~`·`~/…`는 $HOME으로 확장한다(셸을 거치지 않고 `execve`로 띄우므로 tilde 확장을 maru가 직접 한다; $HOME이
  비었거나 절대경로가 아니면 확장을 포기하고 폴백). 형식은 맞지만 **없는 디렉터리**면 자식 셸의 `chdir`이 실패해
  **$HOME으로 graceful 폴백**한다(세션 안 깨짐). 경로에 공백이 있어도 따옴표 없이 그대로 쓴다(값은 양끝 공백만
  다듬는다). **비어 있으면(기본)** maru를 띄운 cwd를 상속하되, 그 cwd가 `/`이면(`.app` 더블클릭·`open`·launchd로
  띄운 흔한 증상) **$HOME으로 올린다** — Ghostty가 launchd/`open` 실행을 `home`으로 보는 것과 같은 결(터미널에서
  `maru`로 띄우면 cwd가 `/`가 아니라 그대로 상속).

- **`workspace.tab-inherit-cwd`** — 새 워크스페이스 탭(`new_tab`)과 새 Term(`new_term`)의 cwd 상속 여부.
  `true`(기본)면 포커스 cwd 상속, `false`면 `root`. Term 탭은 워크스페이스 탭과 같은 '탭'이라 이 토글이 함께
  관할한다.

- **`workspace.split-inherit-cwd`** — 새 분할(`split_*`, 팬)의 cwd 상속 여부. `true`(기본)면 포커스 cwd
  상속, `false`면 `root`.

> **베이스/결정**: 동작·기본값·키 의미를 모두 **Ghostty**(`working-directory`,
> `window/tab/split-inherit-working-directory`, 모두 기본 `true`)에 맞췄다(레퍼런스는 동작만 비교, 코드
> 미참고). 새 split/탭이 현재 디렉터리를 물려받는 동작은 tmux `split-window`·iTerm2 새 split의 보편 관례이기도
> 하다. Ghostty의 `window-inherit-working-directory`(창 간 상속)는 maru에선 **두지 않는다** — 새 창은 별도
> 세션(AppSession)이라 직전 창의 포커스 cwd를 알 길이 없어 항상 `root`에서 연다(Ghostty도 "`working-directory`는
> 주로 첫 창에 쓰인다"고 한다). 새 Term(`new_term`)은 Ghostty에 없는 maru 고유(pane 내 가로 탭)라 가장 가까운
> '탭'으로 보고 `tab-inherit-cwd`에 묶었다.
>
> **퀵 터미널**(`toggle_quick_terminal`)도 `workspace.root`에서 연다 — 별도 세션(독립 `AppSession`)이라 메인 창의
> 포커스 cwd를 상속하지 않고 항상 고정 `root`(없으면 상속/home 폴백)를 쓴다. 이것도 Ghostty와 같다: Ghostty의
> 퀵 터미널은 부모 surface 없이 **fresh `SurfaceConfiguration`**으로 만들어져 전역 `working-directory`로 떨어지고
> 메인 창 cwd를 상속하지 않는다(`QuickTerminalController` — 메인 창/탭/split만 `ghostty_surface_inherited_config`로
> 상속). 즉 `workspace.root`를 정하면 퀵 터미널 시작 경로도 거기로 바뀐다.
>
> 워크스페이스 **복원**(이전 세션 재시작)은 이 값과 무관하다 — 저장된 surface별 cwd를 그대로 쓴다
> ([Workspace Restore 전략](workspace-restore.md)). `workspace.*`는 새로 여는 창/탭/분할에만 적용된다.

### `$TERM` (`term`)

셸에 줄 `$TERM` 값이다. 기본은 **`xterm-maru`** — Maru 자체 terminfo 항목이다(짧은 alias `maru`).
Maru가 이 terminfo 소스를 바이너리에 내장하고, 자식 셸을 띄울 때 자기 캐시(`${XDG_CACHE_HOME:-~/.cache}/maru/terminfo`
— 다른 maru 캐시와 같은 base)에 자동 컴파일(`tic`)해 자식 env에 `TERMINFO=<그 캐시>`를 실어준다. 그래서 **로컬은 별도 설치 없이**
`xterm-maru`가 동작한다(비침습 — `~/.terminfo`나 시스템을 안 건드림). `tic`이 없거나 컴파일이 실패하면
**`xterm-256color`로 자동 폴백**해 로컬이 절대 깨지지 않는다(Ghostty의 번들 terminfo + `TERMINFO` env
방식과 같은 결 — `pty/macos.zig`의 `resolveTerm`).

> **캐시 자동 갱신**: 캐시 디렉터리에 내장 terminfo의 버전 지문(`.maru-version`)을 함께 둔다. maru를 업데이트해
> terminfo 캡이 바뀌면 지문이 달라져 **다음 셸 spawn이 stale 캐시를 자동 재컴파일**한다(예전엔 한 번 컴파일하면
> 안 바꿔, 캡을 늘려도 기존 캐시에 반영되지 않았다). 보통은 손댈 일이 없지만, 강제·진단용으로 `maru terminfo`
> 서브커맨드를 둔다:
>
> ```sh
> maru terminfo            # 상태(캐시 경로 + xterm-maru 해석 여부)
> maru terminfo --refresh  # 캐시를 강제로 비우고 다시 컴파일
> maru terminfo --clear    # 캐시 삭제(다음 실행이 자동 재컴파일)
> maru terminfo --path     # 캐시 경로만 출력(스크립트용)
> ```

`xterm-maru`가 알리는 캡(Maru가 실제 지원하는 것만 정직하게 — 없는 걸 광고하면 원격 프로그램이 오작동):
- **동기화 출력(`Sync`, DECSET 2026)** — tmux가 재그리기를 한 프레임으로 묶어 **tmux 레이아웃 플리커가 사라진다**.
- **truecolor(`Tc`)** — 24-bit 색.
- **bracketed paste(`BE`/`BD`, DECSET 2004)** — nvim/vim의 안전한 붙여넣기.
- **OSC 52 클립보드 set(`Ms`)** — tmux `set-clipboard` 등이 시스템 클립보드에 쓴다(`osc52.write=allow`라 정직; read는 deny).
- **커서 스타일(`Ss`/`Se`, DECSCUSR)** — vim이 모드별 bar/underline/block 커서를 전환한다(원격에서도).
- **focus 이벤트(`fe`/`fd`+`kxIN`/`kxOUT`, DECSET 1004)** — 창 포커스 in/out 보고(vim FocusGained/Lost).

`use=xterm-256color`를 토대로 위 캡을 더한다. 적합성은 `mise run terminfo-check`가 컴파일 + 각 캡의 실제 바이트 round-trip으로 검증한다("추측 말고 캡처").

드물게 셸 설정/프레임워크가 특정 `$TERM`을 기대하면 바꿀 수 있다:

```conf
term = xterm-256color   # 표준값으로 되돌리기
term = xterm-ghostty    # 다른 값(그 terminfo가 설치돼 있어야 함)
```

> 시스템 전역이나 **Maru 밖의 셸**(예: 다른 터미널에서 Maru에 붙는 경우)에서도 `xterm-maru`를 쓰려면
> `mise run install-terminfo`로 `~/.terminfo`에 설치한다(Maru 안에서는 위 자동 캐시로 충분해 불필요).

> **원격(SSH) 동작**: terminfo는 프로그램이 읽는 머신에 있어야 한다. 기본이 `xterm-maru`인데 maru의 `TERMINFO`는
> 로컬 env라 ssh가 안 따라가므로, 그대로 두면 항목 없는 원격에서 `vim`/`tmux`/`mux`/`less`가 커서·레이아웃이 깨진다
> (`unknown terminal type` 또는 커서가 엉뚱한 위치). **그래서 통합 zsh는 기본적으로** `ssh`를 가리는 함수로, `TERM`이
> `xterm-maru`일 때 **그 `ssh` 호출에 한해** `TERM=xterm-256color`(모든 원격이 가진 표준값)로 낮춰 넘긴다 — 평범한
> `ssh`가 그대로 안 깨진다(Ghostty `ssh-env`와 같은 결). 별도 설정 없이 동작하며, `TERM`을 직접 `xterm-256color` 등으로
> 바꿔 뒀으면 함수를 안 만들어 평범한 `ssh` 그대로다(graceful). **주의**: 이 보호는 **zsh 전용**이다(bash/fish는 셸 통합
> 미구현 — 그 셸을 쓰면 `term = "xterm-256color"`로 두거나 아래처럼 원격에 직접 설치한다).
>
> 원격에서도 `xterm-maru` 이점(Sync 등)을 **그대로 살리려면**(다운그레이드 대신 원격에 항목을 심으려면) **`maru ssh`** 를
> 쓴다 — 원격에 terminfo를 먼저 심고 평범한 `ssh`로 넘어간다. `shell-integration.ssh = true`면 통합 zsh가 평범한 `ssh`를
> 자동으로 `maru ssh`로 라우팅한다(기본 off, opt-in — 이게 켜지면 위 다운그레이드보다 우선한다):
>
> ```sh
> maru install-cli              # maru 바이너리를 ~/.local/bin/maru에 symlink(셸에서 maru를 쓰려면 한 번)
> maru ssh <host>               # 원격에 xterm-maru 설치 후 exec ssh
> maru ssh --terminfo-only <host>   # 설치만(세션 없음) — ssh 래핑을 원치 않을 때
> ```
>
> (`maru install-cli`는 현재 maru 바이너리를 `~/.local/bin/maru`에 링크해 PATH에서 `maru`를 쓸 수 있게
> 한다 — sudo 불필요. `~/.local/bin`이 PATH에 없으면 추가 방법을 안내한다.)
>
> `maru ssh`는 terminfo 소스를 바이너리에 내장해 **로컬 설치 없이도** 동작한다(자기완결 — `install-terminfo`는
> 로컬 셸에서 `term = "xterm-maru"`를 쓸 때만 필요하다). 원격에 `tic`이 없거나
> 설치가 실패하면 자동으로 `TERM=xterm-256color`로 폴백해 세션이 깨지지 않는다. 키/agent 인증이면
> ControlMaster로 **단일 연결**(인증 1회)에서 설치와 세션을 함께 처리한다. `maru ssh`는 **대화형
> 세션용**이다 — `maru ssh host cmd`처럼 원격 command를 붙이면 terminfo 설치를 건너뛰고(설치 스크립트가
> command와 충돌해 이중 실행되는 것을 막는다) `xterm-256color`로 연결한다.
>
> **설치 캐시**: 한 번 설치에 성공한 목적지는 `${XDG_CACHE_HOME:-~/.cache}/maru/ssh-terminfo-hosts`에
> 기록돼, 다음 접속부터 설치 단계를 건너뛴다(매 접속 설치 round-trip 제거). 원격 `~/.terminfo`를 비웠다면
> (스테일) `maru ssh --terminfo-only <host>`로 **강제 재설치**하거나 캐시 파일을 지운다(`rm
> ~/.cache/maru/ssh-terminfo-hosts`). 수동으로 한 줄로 설치하려면:
>
> ```sh
> infocmp -x xterm-maru | ssh <host> 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'
> ```

> Maru는 대화형 셸을 macOS `login(1)`로 감싸 띄운다(Terminal.app·Ghostty와 동일) — 전체 로그인
> 세션(getlogin·SHELL·utmp·hushlogin)을 셋업하고 `.zprofile`/`.zlogin`까지 source한다. 그래서
> PATH·EDITOR·키바인딩(예: `bindkey -e`로 `Cmd+←/→`=줄 시작/끝)이 사용자 환경대로 잡혀, 대개 `term`을
> 안 건드려도 정상 동작한다. 키바인딩 해석은 터미널이 아니라 셸의 책임이다 — 터미널은 `\x01` 같은
> 바이트만 보낸다.

> 빈 값(`term =`)은 무시하고 기본값을 유지한다. env를 명시로 주는 테스트 경로에선 이 값이 무시된다.

### 환경변수 주입 (`env.<KEY>`)

새로 띄우는 셸에 줄 환경변수를 정한다. 여러 줄을 둘 수 있고, 각 줄의 `env.` 뒤가 변수 이름, `=` 뒤가 값이다.

```conf
env.EDITOR = nvim
env.LANG = en_US.UTF-8
env.MY_FLAG = a b c   # 값 내부 공백은 보존(양끝만 다듬는다), 빈 값(env.FOO =)도 허용
```

- **병합 정책**: 부모(maru를 띄운) 환경을 상속한 뒤, maru가 관리하는 변수(`TERM`/`COLORTERM`/`TERM_PROGRAM` 등)를
  덮어쓰고, **그 위에** 이 `env.*` 값을 upsert한다 — 같은 KEY가 이미 있으면 덮어쓰고 없으면 추가한다. 즉 `env.*`가
  일반 변수에는 우선한다(부모 상속을 끊지 않는 "부모 + 사용자" 모델 — Ghostty `env`와 같은 결).
- **내부 예약 키**: control-plane selector `MARU_PANE_ID`는 Term identity의 단일 출처라 `env.*` 적용 뒤 spawn
  request 값으로 최종 upsert한다. 이 키의 사용자 설정은 적용되지 않는다.
- **TERM은 `term` 키로**: `$TERM`은 `term =`이 단일 출처다. `env.TERM = ...`으로도 덮을 수 있으나(마지막 적용이라
  이김) terminfo 해석과 어긋날 수 있어 권장하지 않는다.
- 같은 일반 `env.KEY`를 여러 줄 쓰면 **나중 줄이 이긴다**(spawn 시 순서대로 upsert). 빈 KEY(`env. =`)는 무시(diagnostic).
- **적용 시점**: 새로 여는 셸(첫 창·새 탭/Term·분할)에만 적용된다. 런타임 **Reload Config**는 이미 떠 있는 셸의
  환경을 바꾸지 않는다(프로세스 env는 spawn 후 불변 — 이후 연 셸부터 반영).
- **베이스/결정**: 상속 + override 모델은 Ghostty `env`(부모 상속 위에 사용자 값 추가)를 베이스로 했다. 저장은
  값 보존이 기본이다(config 파일은 사용자 소유) — 민감값 마스킹은 GUI 표시·trace에만 적용한다([필수 프로젝트 규칙]
  redaction 기준, settings-page.md §8).

### 대화형 셸 (`shell.command` / `shell.args`)

기본적으로 maru는 `$MARU_INTERACTIVE_SHELL`→`$SHELL`→`/bin/sh` 순으로 셸을 정하고 `-i`로 띄운다. 이를
사용자가 바꿀 수 있다.

```conf
shell.command = /opt/homebrew/bin/fish
shell.args = -i -l    # 공백으로 토큰 분리(따옴표 미지원). 빈 값이면 인자 없음
```

- **`shell.command`** — 셸 실행 파일 경로. 비어 있으면(기본) 위 자동 결정. maru는 셸을 거치지 않고 `execve`로
  직접 띄우므로 **절대경로**여야 한다(PATH 탐색 없음). 없는 경로면 spawn이 실패한다.
- **`shell.args`** — argv(command 제외). 공백으로 토큰을 나눈다(`-i -l` → `["-i", "-l"]`). 따옴표·이스케이프는
  지원하지 않는다(셸 플래그는 보통 단순). 빈 값이면 인자 없이 띄운다. 미설정 시 기본 `-i`.
- **login 래퍼는 유지**: macOS는 셸을 `login(1)`로 감싸 전체 로그인 세션을 셋업하고(Terminal.app·Ghostty 동일),
  이 `command`/`args`가 그 안의 `exec -l <command> <args>`로 들어가 최종 로그인 셸이 된다. 즉 셸을 바꿔도 로그인
  셸 셋업(PATH·`.zprofile` 등)은 그대로 동작한다.
- **적용 시점**: 새로 여는 셸(첫 창·새 탭/Term·분할)에만. 런타임 Reload Config는 이미 떠 있는 셸을 안 바꾼다.
  퀵 터미널·controlled smoke(테스트용 `/bin/sh -c`)에는 영향 없다(대화형 셸에만 적용).
- **베이스/결정**: Ghostty `command`/`shell`(사용자 지정 셸 프로그램)에 대응한다. Ghostty의 `command`는 `/bin/sh -c`로
  한 문자열을 실행하지만, maru는 `execve` 직접 모델이라 **경로 + argv 토큰 배열**(셸-split 없음)로 둔다 — quoting
  모호성을 피하고 실패 원인을 줄인다.

### 셸 통합 ssh 라우팅 (`shell-integration.ssh`)

```
shell-integration.ssh = true    # 평범한 ssh를 maru ssh로 자동 라우팅 (기본 false)
```

이건 **다운그레이드 대신 원격에 항목을 심는 "업그레이드" 경로**다. 끄면(기본) 통합 zsh는 `TERM=xterm-maru`인 `ssh`를
`xterm-256color`로 **다운그레이드**해 원격이 안 깨지게만 한다(위 `term` 절의 "원격(SSH) 동작"). 켜면 그 다운그레이드 대신
**통합 zsh에서 평범한 `ssh`를 입력해도** maru가 그 호출을 `maru ssh`로 라우팅해 `xterm-maru`를 원격에 심는다 — 매번
`maru`를 앞에 붙이지 않아도 원격에서 xterm-maru 이점(Sync 등)을 그대로 쓴다.

> **동작**: maru가 자식 셸 env에 현재 실행 파일 경로(`MARU_BIN`)와 플래그(`MARU_SSH_INTEGRATION`)를
> 주입하고, Maru 통합 `.zshenv`가 이 둘이 모두 있을 때만 `ssh`를 `maru ssh`로 위임하는 함수를 정의한다(이게
> 기본 다운그레이드 함수보다 우선). 같은 maru 바이너리가 `maru ssh`를 처리하므로 `install-cli` 없이도 동작한다.
>
> **기본 off인 이유**(opt-in): 원격 terminfo 설치는 침습적이라 사용자 동의가 필요하다(Ghostty도 `ssh-*`를 기본
> off로 둔다). 끄면(기본)에도 위 다운그레이드로 원격이 안 깨지므로, 이 옵션은 "원격에서도 xterm-maru를 쓰고 싶을
> 때"만 켜면 된다.
>
> **범위/우회**: zsh 통합이 켜진 대화형 셸에서만 적용된다(통합이 없으면 함수가 정의되지 않는다). 한 번만
> 평범한 ssh로 가려면 `command ssh ...` 또는 `\ssh ...`. `maru ssh`와 동일하게 **대화형 세션용**이라
> `ssh host cmd`(원격 command)는 terminfo 설치를 건너뛰고 `xterm-256color`로 연결한다.

### 키바인딩 (`keybind`)

`keybind = <조합> = <action>` 한 줄에 하나씩, 여러 줄을 둘 수 있다(값 안에 `=`가 한 번 더 있는
형태다 — config의 첫 `=`는 `keybind` key를, 두 번째 `=`는 조합과 action을 가른다).

```conf
keybind = Cmd+T = new_tab
keybind = Cmd+W = close_tab
keybind = Cmd+Shift+Right = next_tab
keybind = Cmd+Shift+Left = previous_tab
keybind = Ctrl+Cmd+1 = select_tab:0
keybind = Cmd+D = unbind
keybind = F2 = text:hello
keybind = Cmd+E = ctrl:[
keybind = F4 = esc:[2J
```

- **조합**: `Cmd`/`Ctrl`/`Alt`/`Shift`(대소문자 무관)를 `+`로 잇고 마지막에 키. 키는 글자 한 자,
  숫자, `Esc`/`Tab`/`Enter`/`Space`/`Backspace`/`Up`/`Down`/`Left`/`Right`/`F1`~`F24`, 그리고 `+`
  자체는 `Plus`로 쓴다(예: `Cmd+Plus`).
- **action**: 워크스페이스 `new_tab`·`close_tab`·`next_tab`·`previous_tab`·`select_tab:N`(N=0부터),
  포커스 기반 닫기 `close_focused`, Term 전용 `new_term`·`close_term`·`next_term`·`previous_term`, 분할 `split_horizontal`·`split_vertical`,
  pane 포커스 `focus_pane_left`·`focus_pane_right`·`focus_pane_up`·`focus_pane_down`, split 순환 `next_pane`·`previous_pane`,
  폰트 크기 `increase_font_size`·`decrease_font_size`(보폭 고정 1pt)·`reset_font_size`·`set_font_size:N`
  (N=절대 pt, 6~72로 클램프 — 예: `Ctrl+Cmd+1 = set_font_size:14`로 크기 프리셋), 그리고 `select_all`·
  `clear_screen`(화면+스크롤백 비우기, 빌트인 ⌘K — alt 화면 무동작, 셸 프롬프트면 ^L로 재그림. 자세히는
  [키 입력과 단축키](key-input-and-shortcuts.md))·`toggle_find`·`find_next`·
  `find_previous`·`toggle_command_palette`·`toggle_settings`(세팅 화면 ⌘,)·`reset_settings`
  (설정을 기본값으로 되돌리는 통합 리셋 — 커맨드 팝업 "Reset All Settings to Defaults". 단
  `session.keep-alive-after-quit`은 위 소유권 예외대로 현재 값을 보존·materialize하고, 나머지 config 파일의
  schema·특수 키·주석은 내장 기본 상태로 돌린다).
- **`unbind`**: action 자리에 `unbind`를 적으면 그 조합의 **빌트인 기본 동작을 끈다**(예:
  `keybind = Cmd+T = unbind` → Cmd+T가 새 Term을 안 연다). 끈 조합은 빌트인 테이블을 건너뛰어
  `Cmd`+키는 아무 동작도 안 하고, 그 외 조합은 셸로 입력이 전달된다. 다른 action을 지정하면(덮어쓰기)
  그게 우선이라, `unbind`는 "끄기" 전용이다.
- **터미널 매크로**: action 자리에 아래 접두사를 쓰면 그 조합이 **셸로 바이트를 보낸다**(앱 동작 대신):
  - `text:<문자열>` — 문자열을 그대로 입력(예: `text:hello`).
  - `esc:<payload>` — `ESC`(0x1b)를 앞에 붙인 시퀀스(예: `esc:[2J` → 화면 지우기 `ESC [2J`).
  - `ctrl:<글자 한 자>` — 그 글자의 컨트롤 바이트(예: `ctrl:[` → `ESC`, `ctrl:c` → `Ctrl+C`).
    매핑 가능한 글자는 `@`, `A`~`Z`, `[`, `\`, `]`, `^`, `_`, `Space`, `?`다(C0 컨트롤).
  접두사인데 payload가 비었거나(`text:`) `ctrl:`이 글자 한 자가 아니거나 매핑 안 되면 그 줄만 무시(forgiving).
- **전역 단축키 (`global:`)**: 조합 앞에 `global:`을 붙이면 그 단축키를 **OS 레벨에 등록**해, Maru가
  활성 창이 아니어도 동작한다(`keybind = global:<조합> = <전역 action>`). 전역 action은:
  - `toggle_window` — 창이 숨김/비활성이면 보이고 앞으로(show + 활성화), 이미 활성+보임이면 숨긴다(토글).
  - `show_window` — 항상 창을 보이고 앞으로 가져온다(숨기지 않음).
  - `toggle_quick_terminal` — quick terminal(별도 세션 오버레이 패널, 화면 상단 드롭다운)을 토글한다.
    첫 호출에서 두 번째 셸 세션을 띄우고, 다시 누르면 숨긴다. 화면 위에서 슬라이드해 내려오고/올라가며,
    포커스를 잃으면(다른 창/앱 클릭) 자동으로 숨는다.

  예: `keybind = global:Cmd+Alt+Space = toggle_window`. 전역 단축키는 **별도 네임스페이스**라 같은 조합을
  in-app 바인딩으로도 둘 수 있고(충돌 아님), 전역끼리만 중복을 막는다(첫 줄 우선). 매핑 가능한 키는 글자/
  숫자/`Space`/방향/`F1`~`F20` 등이며, `+`(Plus)·`Insert`처럼 macOS 가상 키코드가 없는 키는 등록에서 제외된다.
- 같은 조합을 두 번 바인딩하면 **첫 줄이 이긴다**(in-app은 action·`unbind`·매크로 통틀어 조합당 한 줄, 전역은
  전역끼리 — 중복은 무시 + diagnostic). 한 조합을 in-app 앱 동작과 매크로에 동시에 못 묶는다(첫 줄 우선이라
  충돌이 안 생긴다). 조합/action을 못 읽으면 그 줄만 무시(forgiving).

> **현재 범위**: in-app 키바인딩(앱 액션·`unbind`·터미널 매크로)은 `KeyBindingResolver`로 동작에
> 연결된다. 전역 단축키(`global:`)는 config 파싱 → OS 등록용 키코드 매핑 → macOS Carbon
> `RegisterEventHotKey` 등록 → 동작(창 토글/표시, quick terminal 토글)까지 동작한다(앱이 비활성이어도
> 발화). quick terminal의 슬라이드 애니메이션과 `auto-hide` 포커스 정책은 구현됐다. Esc 숨김은 vim 등 terminal
> 입력과 충돌하므로 의도적으로 채택하지 않는다.

## 검증 동작 (forgiving)

한 줄의 오타가 전체 설정을 깨지 않게, **치명적 오류는 메모리 부족뿐**이다. 그 외는 모두 해당
필드의 기본값을 유지하고 diagnostic(무시된 줄 번호 + 이유)으로 남긴다:

- 알 수 없는 key → 무시.
- `=` 없는 줄 → 무시.
- `font.size`가 숫자가 아니거나 1~512 밖 → 기본 14 유지.
- `font.line-height`가 숫자가 아니거나 0.5~3.0 밖 → 기본 1.0 유지.
- `font.letter-spacing`이 숫자가 아니거나 -8~32 밖 → 기본 0.0 유지(음수는 허용).
- `cursor.shape`/`cursor.blink`가 허용 값이 아님 → 기본 유지.
- 색이 `#RRGGBB` 형식이 아님 → 기본 색 유지.

`MARU_DEBUG=1`로 실행하면 무시된 줄이 `config line N: ...` 경고로 보인다. (값 의미 검증은
`appearance.resolve`와 `appearance.parseHexColor` 단일 출처를 재사용하므로, 로더가 통과시킨 값은
resolve 단계에서 다시 실패하지 않는다.)

## 구현 경계

- **순수 파서** `config.parseConfig`(`src/config/loader.zig`)는 파일시스템 없이 텍스트 →
  `theme.Config`로 파싱한다(단위 테스트로 고정, Linux CI 포함). I/O 래퍼 `config.loadConfigDefault`
  /`loadConfigFile`이 경로 해석과 파일 읽기를 감싼다.
- **소유권**: 파싱된 문자열(`font.family`)은 `Parsed.arena`가 소유한다. `appearance.resolve`가 그
  family 슬라이스를 빌리므로(복사 안 함), 호출자(app session)는 `Parsed`를 세션 동안 보관하고
  종료 시 `deinit`한다. 색은 resolve가 `Rgb` 값으로 변환하므로 수명 의존이 없다.
- app session은 시작 시 `config.loadConfigDefault(io, allocator)`로 로드해 `resolveAppearance`에
  넘긴다. resolve가 (방어적으로) 실패하면 기본 appearance로 떨어진다.

## 범위와 후속

appearance(폰트/테마/커서)와 키바인딩 **파싱**까지 구현됐다. 의존성 순서상 config가 먼저 와야
뒤따르는 설정형 기능이 하드코딩 후 재작업되지 않는다([구현 계획](implementation-plan.md) 참조).
후속:

- **키바인딩 dispatch**: 파싱된 `KeyBindingResolver`로 실제 app action(탭 열기 등)을 실행한다 —
  8단계 탭/quick terminal/global shortcut에서.
- **동작 토글**: paste 보호, 이모지 grapheme 기본값(DEC mode 2027 강제) 등.
- **terminal 입력 remap**: `<조합> → 바이트` 매크로(TerminalBinding) config.
- **파일 변경 자동 감지 reload**: 파일 watcher로 변경을 감지해 자동 재-resolve(자동 감지만 후속). 메뉴의 수동 **Reload Config**(파일 재로드해 재시작 없이 적용)·**Reset to Defaults**(확인 모달 후 `session.keep-alive-after-quit`은 보존하고 나머지 config를 내장 기본값으로 되돌려 파일을 덮어씀 — 커맨드 팝업 "Reset All Settings to Defaults"와 같은 통합 리셋)는 구현됨.
- **다른 셸(bash/fish) 통합·ssh 라우팅**(보류, 2026-06): 셸 통합(macOS 편집키·OSC 133/7·`shell-integration.ssh` ssh 라우팅)은 **현재 zsh 전용**(`ZDOTDIR`+`.zshenv` 주입)이다. fish는 vendor `conf.d`로 깔끔히 주입할 수 있으나, bash는 maru가 **login 셸**로 띄워(`login=true`) `--rcfile`이 무시되고 `~/.bash_profile`만 읽어 사용자 설정을 안 깨는 주입이 까다롭다(레퍼런스 동작 비교 + 신중한 검증 필요). 그래서 별도 후속으로 둔다 — bash/fish 사용자는 그때까지 직접 `maru ssh`를 쓴다.
- **설정 UI**: 앱 내 세팅 화면(GUI) + config 파일 양방향 반영. 전략·섹션 구조·신규 키·PR 분해는
  [세팅 페이지 전략과 구현 계획](settings-page.md)을 단일 출처로 둔다(계획 단계, 2026-06).
