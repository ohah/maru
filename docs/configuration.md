# 설정(config) 파일

Maru는 시작 시 사용자 설정 파일을 읽어 폰트·색·커서를 적용한다. 이 문서는 파일 위치, 형식, 키,
검증 동작을 정한다. 설정은 **선언적**이고 **forgiving**하다 — 설정 파일이 없거나 일부 줄이 틀려도
터미널은 정상 동작한다.

> 이 문서는 config 토대의 appearance(폰트/테마/커서) + 키바인딩 파싱을 다룬다. 메뉴의 수동 Reload Config·
> Reset to Defaults는 구현됐고, schema 기반 설정 UI는 진행 중이다([세팅 페이지 전략](settings-page.md)).
>
> **여기 있는 키와 파일 위치는 데스크톱 것이다.** 모바일은 파일도 스키마도 따로 두고, 파서·resolve
> 규율만 공유한다 — 무엇을 싣고 어디에 두는지는 [모바일 config](mobile-config.md)가 소유한다.
> 파일 변경 자동 감지 reload와 남은 bespoke 위젯은 후속 단계다(아래 "범위와 후속" 참조).
> 수동 reload의 scrollback·ambiguous/emoji width·ANSI palette·default color·cell metric snapshot은 열린
> in-process terminal과 `runtime_core_command_v1`을 협상한 현재 host-backed terminal에 적용된다. capability
> 없는 구 host의 기존 runtime은 legacy scroll 외 config command가 degraded no-op이다. 새 host-backed terminal은 같은 snapshot을
> `runtime.spawn_full`에 실어 reader 시작 전에 적용하므로 첫 output도 기본값으로 먼저 parse되지 않는다.
> 이 계약의 capability가 없는 이미 실행 중인 구 session host는 새 필드를 조용히 무시할 수 있으므로 config-bearing
> spawn을 거부하고 in-process terminal로 명시적으로 fallback한다. 잘못된 기본값으로 host runtime을 만들지 않는다.

## 문서 구성

이 문서는 **키 표와 파일 형식**을 소유한다. 표는 `build.zig`가 익명 import로 등록하고
`src/config/schema.zig`가 `@embedFile`로 박아 컴파일 타임에 검증하므로(스키마 키가 표에 있는지,
숫자 범위가 `parse_range`와 맞는지) **다른 파일로 옮길 수 없다**.

키별 배경 설명은 주제별로 나눠 소유한다.

| 문서 | 소유 |
|---|---|
| [텍스트와 테마](configuration-text.md) | `theme.preset` 프리셋, `text.ambiguous-width`, `text.emoji-width` |
| [입력과 키바인딩](configuration-input.md) | `input.page-keys`, `input.shift-enter`, `input.ime-enter`, `keybind` |
| [셸과 환경](configuration-shell.md) | `workspace.*`, `term`, `env.<KEY>`, `shell.*`, `shell-integration.ssh`, `ssh.*` |

## 위치

다음 순서로 경로를 정한다.

1. 환경변수 `$MARU_CONFIG`가 있으면 그 경로.
2. 없으면 `$HOME/.config/maru/config`.
3. `$HOME`도 없으면 설정 없이 기본값으로 시작한다.

파일이 없으면 **에러가 아니라** 전부 기본값으로 시작한다(Ghostty와 같은 위치/관례).

## 형식

`key = value` 한 줄에 하나. `#`로 시작하는 줄과 빈 줄은 무시한다(Ghostty식). 값은 양끝 공백을
다듬되 **내부 공백은 보존**한다(예: 폰트명 `JetBrains Mono`). 따옴표는 쓰지 않는다.

### OS별 값 — 키에 `.windows`·`.macos`·`.linux`를 붙인다

**아무 키에나** OS 접미를 붙이면 그 OS에서만 적용된다. 한 config 파일을 여러 OS에서 공유(dotfiles)할 때
`shell.command = /bin/zsh` 한 줄이 Windows에서 깨지는 문제를 푼다. VS Code가 같은 문제를
`terminal.integrated.defaultProfile.windows`/`.osx`/`.linux`로 푸는 것과 같은 모양이다.

```conf
# 기본(접미 없는 줄)
shell.command         = /bin/zsh
# Windows에서만 이긴다
shell.command.windows = C:\Program Files\PowerShell\7\pwsh.exe
font.size.macos       = 14
font.size.linux       = 12
```

**접미 줄은 `그 자리에서` 적용된다 — 우선순위는 파일 순서가 정한다.** 이 파일 형식은 원래 순서 의존이므로
(아래 `theme.preset`·`keybind`) 접미만 예외로 두면 그 규약들이 깨진다. 그래서 접미는 "그 줄을 이 OS에서만
읽는다"는 뜻일 뿐이고, 나머지 규칙은 전부 그대로다.

```conf
shell.command         = /bin/zsh
# 뒤에 있으므로 Windows에서 이긴다
shell.command.windows = C:\...\pwsh.exe
```

- **덮어쓰려면 뒤에 둔다.** 대부분의 키는 나중 줄이 이기므로 접미 줄을 아래에 적는다. 반대로
  **`keybind`는 첫 줄이 이기므로** OS별 바인딩은 기본 줄보다 **위에** 적어야 한다(같은 chord일 때).
  그러면 뒤에 남은 기본 줄에 *"이미 바인딩된 키 조합 — 무시(첫 줄 우선)"* 경고가 뜬다 — **정상이다.**
  두 줄이 같은 chord를 노렸고 앞의 것이 이겼다는 뜻이지, 설정이 잘못됐다는 뜻이 아니다.
- **다른 OS의 줄은 값이 적용되지 않는다.** 다만 **키 이름은 검증**하므로 `bogus.setting.macos`는 어느 OS에서든
  "알 수 없는 키" 경고가 뜬다(값은 그 OS 것일 수 있으므로 값 검증은 하지 않는다).
- **모르는 이름은 접미로 치지 않는다.** `shell.command.freebsd`나 오타 `shell.command.window`는 통째로 키
  이름이 되어 경고가 뜬다 — 조용히 먹히면 사용자가 설정이 반영된 줄 안다. (`.osx`는 VS Code 철자라 받아들이되
  `.macos`를 권한다.)
- 접미는 **키 이름의 일부일 뿐**이라 값 파싱·검증은 기본 키와 완전히 같다.

**알려진 한계 — 설정 GUI는 접미를 모른다.** 사이드바 드래그·⚙ 토글·세팅 화면이 값을 파일에 되쓸 때는 항상
**기본 키**에 쓴다. 그래서 GUI로도 바꾸는 키에 접미를 쓰면 이렇게 된다.

| | 결과 |
|---|---|
| 접미 줄이 기본 줄보다 **뒤** | GUI 변경이 파일에 남지만 **화면에 반영되지 않는다**(접미 줄이 계속 이긴다) |
| 접미 줄이 **앞** | GUI 변경이 정상 반영된다 |
| GUI에서 기본값으로 되돌리기 | 기본 줄만 지워지고 접미 줄은 남는다 |

즉 **GUI로 만지는 키는 접미를 쓰지 않는 편이 낫다.** 접미는 `shell.command`·`font.size`처럼 파일로 관리하는
키에 쓰는 것을 전제로 한다. (`keybind`도 GUI 쓰기 경로가 접미를 모른다 — 파일로만 관리한다.)

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

# 기본 모양 — 앱 DECSCUSR가 지정하면 그게 우선(CSI 0 SP q·RIS면 이 값 복귀)
cursor.shape = block
# true=앱(DECSCUSR)에 위임, false=앱 요청까지 덮어 커서 고정
cursor.blink = true
# 깜빡임 반주기(ms) — cursor.blink=true일 때
cursor.blink-interval-ms = 500
# cursor.blink-fade-ms = 120      # 깜빡임 전환 페이드(ms) — 기본 0(즉각 on/off), 값을 주면 부드럽게
# 커서 색 override(선택). 적으면 테마와 무관하게 커서만 그 색으로 칠한다. 안 적으면 테마를 따른다.
# cursor.color = #ff5555   # 커서 칸 배경(미지정 시 theme.cursor)
# cursor.text  = #101010   # 커서 위 반전 글자색(미지정 시 배경색)

window.padding-top    = 4
window.padding-right  = 8
window.padding-bottom = 4
window.padding-left   = 8
# 또는 대칭 alias: window.padding-x = 8 (좌우 동시), window.padding-y = 4 (상하 동시)
# 배경 투명도(0~1) — default 배경만 투명, 1=불투명
window.opacity        = 1.0
# 앱 frame-loop 주사율(Hz) — 30~120, 기본/권장 60
render.frame-rate     = 60
# 배경 이미지 PNG 경로(절대경로). 기본은 없음이라 이 줄은 예시로만 둔다 —
# 빈 값으로 적으면 "비어 있음" 진단이 뜬다(동작은 기본값 유지).
# window.background-image = /Users/me/wall.png
# 창 뒤 데스크톱 블러 반경(px) — 0=끔, opacity<1일 때만
window.blur           = 0
# 비활성 split pane 디밍(0~1) — 0=끔, 클수록 흐림
window.unfocused-dim  = 0.0
# split 경계선 두께(pt) — 0=숨김, 폰트 크기와 무관한 고정 pt
split.divider-thickness = 1.0
# 파일 패널 외부 링크: in-app | system
file-panel.external-link-target = in-app
```

## 키

| 키 | 타입 | 기본값 | 비고 |
|---|---|---|---|
| `ui.language` | `auto`\|`en`\|`ko` | `auto` | **UI 표시 언어.** `auto`는 OS 로케일을 따르고, 해석 실패·미지원 언어는 `en`으로 떨어진다. **기본값이 `auto`인 이유**: 화면이 이미 한국어라 `en`을 기본으로 두면 이 설정이 생기는 순간 한국어 사용자의 화면이 영어로 바뀐다. 바꾸면 **재시작 없이 다음 프레임에** 반영된다. 번역 범위는 앱 안에서 읽고 판단하는 표면(설정·안내·확인)이고 **메뉴바·CLI·로그는 영어 고정**이다 — 단일 출처: [다국어](i18n.md). 그 외 값은 무시 |
| `font.family` | 문자열 | `JetBrains Mono` | 내부 공백 보존. 비어 있으면 무시(기본 유지). **Windows**: 이 폰트가 설치돼 있지 않으면 `Cascadia Mono` → `Consolas` → `Courier New` 순으로 내려간다([windows-platform.md](windows-platform.md) §2e) — 기본값 `JetBrains Mono`는 Windows에 기본 설치되지 않기 때문이다. OS별로 다르게 두려면 접미를 쓴다(`font.family.windows = Cascadia Mono`) |
| `font.fallback` | 문자열(쉼표 구분) | (없음) | **폴백 폰트** 목록(예: `Apple SD Gothic Neo, Apple Color Emoji`). 주 `font.family`에 없는 글리프(한글·이모지·기호 등)를 그릴 때 이 목록을 앞에 두고 CoreText 기본 폴백을 뒤에 잇는다(`kCTFontCascadeListAttribute`). 각 항목은 앞뒤 공백 trim(내부 공백 보존). 잘못된 폰트명은 무시(best-effort). 비어 있으면 CoreText 기본 폴백만. **Windows**: DirectWrite의 자동 cascade가 `IDWriteFactory2` 이후에만 있어 목록을 앱이 든다 — 이 값 뒤에 내장 티어(`Malgun Gothic` → `Noto Sans KR` → `Microsoft YaHei` → `Microsoft JhengHei` → `Yu Gothic` → `Segoe UI Emoji` → `Segoe UI Symbol`)를 잇는다. **비워 둬도 그 티어는 동작한다** — 고정폭 라틴 폰트에 한글이 없어 비워 두면 한글이 빈 칸이 되기 때문이다(§2e 실측) |
| `font.family-bold` | 문자열 | (없음) | **bold(SGR 1) 글자용 폰트 패밀리**. 비어 있으면(기본) 주 `font.family`의 bold variant를 쓴다(variant가 없으면 regular 폴백 — 굵기를 합성하지 않음). 설정하면 bold cell을 이 패밀리로 그려 본문과 다른 글꼴로 강조할 수 있다. `font.fallback` cascade를 상속해 bold 한글·이모지도 폴백한다. 패밀리를 못 찾으면 주 폰트 bold로 폴백(best-effort) |
| `font.family-italic` | 문자열 | (없음) | **italic(SGR 3) 글자용 폰트 패밀리**. 비어 있으면(기본) 주 `font.family`의 italic variant를 쓴다(없으면 regular 폴백). italic 렌더는 이 기능과 함께 추가됐다(이전엔 SGR 3이 기울임으로 안 그려짐). bold+italic은 bold face(`font.family-bold` 또는 주 폰트 bold)에 italic을 더한다. 패밀리를 못 찾으면 주 폰트 italic로 폴백 |
| `font.ligatures` | 불리언 | `true` | **프로그래밍 합자**(`=>`·`!=`·`//` 등). 켜면 폰트가 정의한 `liga`/`clig`/`calt`를 그대로 두어 JetBrains Mono·Fira Code 같은 코딩 폰트가 이어진 모양으로 그린다. 끄면 셋을 모두 꺼 글자 그대로 그린다. **기본 켬**은 Ghostty(`-calt`로 꺼야 함)·kitty(`disable_ligatures none`)·WezTerm 관례를 따른 것이다(iTerm2만 기본 해제). 등폭 격자는 어느 쪽이든 유지된다 — 코딩 폰트의 합자는 대개 `calt`로 구현돼 칸마다 조각을 하나씩 놓기 때문이다 |
| `font.size` | 숫자 | `14` | 1~512 범위. 범위 밖/비숫자는 무시. ⌘+/⌘-(Bigger/Smaller)는 이 값을 **고정 1pt씩** 바꾸고 ⌘0(Actual Size)이 복귀시킨다(보폭은 설정 불가) |
| `font.line-height` | 숫자 | `1.0` | 행간 배수. 1.0=CoreText 자동 cell 높이, 1.5=50% 더 큰 줄 간격. 0.5~3.0 범위. 범위 밖/비숫자는 무시. 늘어난 높이는 글자를 셀 안 세로 가운데로 그려 위아래 여백이 된다 |
| `font.letter-spacing` | 숫자 | `0.0` | 자간(논리 pt). 0=advance 그대로, 양수=칸 넓힘, 음수=칸 좁힘. -8~32 범위(음수 허용). 범위 밖/비숫자는 무시. 늘어난 폭은 글자를 셀 안 가로 가운데로 그려 좌우 여백이 된다 |
| `theme.preset` | 프리셋 이름 | `maru` | 이름 붙은 컬러 테마 **base**. 색 세트(배경/전경/커서/선택 + ANSI 16색)를 한 번에 고른다. `maru`·`ghostty`·`gruvbox-dark`·`solarized-dark`·`solarized-light`·`dracula`·`catppuccin-mocha`·`catppuccin-latte`·`light-pink`·`dark-pink`·`rose-pine`·`rose-pine-dawn`·`tokyo-night`·`nord`·`one-dark`·`one-light`. 개별 `theme.*` 키를 **이 줄 뒤에** 두면 그 색만 override(순차 적용, 나중 줄 우선). 그 외 값은 무시. [컬러 테마 프리셋](configuration-text.md#컬러-테마-프리셋-themepreset) 참조 |
| `theme.follow-system` | `true`\|`false` | `false` | **시스템 라이트/다크 외관을 따라 테마 색을 자동 전환**한다. `true`면 macOS가 라이트면 `theme.preset-light`, 다크면 `theme.preset-dark` 색 세트로 라이브 교체하고 외관이 바뀌면 즉시 따라간다. **켜져 있는 동안 `theme.preset`·개별 `theme.*` 색은 무시**되고 시스템이 색을 정한다(끄면 파일의 그 값으로 복귀). 시스템 외관 교체는 config 파일에 영속하지 않는다. 기본 `false`(현행 — 수동 테마) |
| `theme.preset-light` | 프리셋 이름 | `solarized-light` | `theme.follow-system`이 켜졌을 때 **라이트** 외관에 쓸 프리셋(위 `theme.preset`과 같은 이름 집합). 라이트 테마(`solarized-light`·`catppuccin-latte`·`light-pink`·`rose-pine-dawn`·`one-light`)를 권장 |
| `theme.preset-dark` | 프리셋 이름 | `maru` | `theme.follow-system`이 켜졌을 때 **다크** 외관에 쓸 프리셋. 다크 테마(`maru`·`gruvbox-dark`·`dracula`·`tokyo-night`·`nord`·`one-dark`·`rose-pine`·`dark-pink` 등)를 권장 |
| `theme.background` | `#RRGGBB` | `#101010` | 16진 색. 형식 오류는 무시 |
| `theme.foreground` | `#RRGGBB` | `#e8e8e8` | |
| `theme.cursor` | `#RRGGBB` | `#ffffff` | |
| `theme.selection` | `#RRGGBB` | `#334455` | 선택 하이라이트 배경 |
| `theme.palette.0`~`theme.palette.15` | `#RRGGBB` | xterm 표준색 | ANSI 16색(0~15) override — `ls`/`vim`/프롬프트 색 테마 완성용. 적은 인덱스만 덮어도 됨(나머지는 xterm 표준 폴백). 우선순위는 **OSC 4(앱 동적 설정) > config > xterm256**: 앱이 OSC 4로 색을 바꾸면 그게 우선이고, RIS·OSC 104(리셋) 후엔 다시 이 config 값으로 돌아온다. 범위 밖 인덱스(16+)·비정수 인덱스·형식 오류 색은 무시(그 인덱스는 기본 유지) |
| `theme.syntax.keyword`·`theme.syntax.string`·`theme.syntax.number`·`theme.syntax.comment`·`theme.syntax.property`·`theme.syntax.type`·`theme.syntax.function`·`theme.syntax.punctuation`·`theme.syntax.tag`·`theme.syntax.attribute`·`theme.syntax.invalid` | `#RRGGBB` | (파생) | **구문 강조 색을 역할별로 직접 정한다**(편집기·diff·파일 패널 편집기가 함께 쓴다). 안 정한 역할은 터미널 팔레트에서 파생한다 — keyword·attribute=밝은 magenta, string=밝은 green, number=밝은 yellow, function·property=밝은 blue, type=밝은 cyan, tag·invalid=밝은 red, comment·punctuation=전경색을 배경 쪽으로 흐린 색. 그래서 **아무것도 안 정하면 지금과 같다**. **명시한 색은 대비 보정을 받지 않는다**(`theme.background`·`theme.foreground`와 같은 규율 — 보정은 프로그램이 고르는 ANSI 팔레트에만 건다). `theme.follow-system`이 켜져 있으면 다른 개별 `theme.*` 색과 함께 무시되고, `theme.preset`이 **뒤 줄**에 오면 지워진다(순차 적용). 형식 오류 색·모르는 역할 이름은 무시(그 역할은 파생 유지) |
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
| `session.keep-alive-after-quit` | `true`\|`false` | `false` | **영속 터미널 세션**(실험적 opt-in) — 정상 GUI Quit 뒤에도 일반 Window의 terminal runtime을 `maru-sessiond`가 유지하고 재실행 시 같은 `host_id:runtime_id`에 재접속한다([전체 P4 종료 gate](persistent-session-host.md#p4--일반-window-default-readinessbackground-알림)). **기본값은 `false`인 opt-in으로 유지한다.** 새 일반 Workspace/Term/split부터 토글 값을 적용하고 열린 Term은 process 사이로 이동하지 않는다. quick은 항상 in-process이고 Quit 때 종료된다. 현재 host 실패는 one-shot notice 뒤 local fallback하고 handle을 쓰지 않으며, P4 전에 persistent `not preserved` 상태를 추가한다. Workspace 설정에서 편집하고 모든 Window가 앱 전역 snapshot을 공유한다. global Reset은 `absent`를 absent로 유지하고 explicit valid/invalid intent는 기본값과 같아도 canonical bool override로 보존하며, row Reset/Backspace는 값·override·파일을 바꾸지 않고 Workspace 토글을 직접 바꾸라는 notice를 낸다. 사용자가 토글을 직접 바꿀 때만 true/false를 교체한다. 자동 default-on과 frozen-release migration은 현재 P1~P5 완료 조건이 아닌 G3 release 백로그이며 사용자 재승인 전에는 시작하지 않는다. 업데이트 호환성의 A runtime→B exact adapter attach는 이 기본값 전환과 별도로 검증한다. 외부 CLI(P5)와 자동 migration(U5) 전체는 opt-in 사용의 선결이 아니고 나머지 조건은 링크된 P4 gate가 단일 출처다 |
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
| `chrome.tab-style` | `connected`\|`underline`\|`pill` | `underline` | 활성 탭 룩(직교 축). `underline`(기본)=언더바만(미니멀, 배경 박스 없음), `connected`=터미널 본문색 cutout + 테마 accent 언더바(아래 본문과 이어짐), `pill`=lifted 회색으로 채운 둥근 캡슐 + 옅은 밝은 테두리(Warp식 떠 있는 pill, 포커스=fill 밝기). `theme.preset`(색)과는 직교. 자세히는 [Chrome 전략 §7](chrome-strategy.md) |
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
| `editor.wrap` | `true`\|`false` | `true` | 네이티브 파일 편집기에서 본문 폭을 넘는 줄을 **다음 시각 행으로 접을지**([세로 축 매핑](native-editor-visual-mapping.md) §4). 접힌 행에는 줄 번호를 비운다(VSCode 관례). **기본값이 그 문서의 방침(*"가로 스크롤이 기본이고 랩은 토글"*)과 반대인 이유**: 가로 스크롤이 아직 구현되지 않아, 끄면 본문 폭에서 잘린 뒤를 볼 수단이 없다. 가로 스크롤이 붙으면 기본값을 `false`로 되돌린다. 터미널에는 영향이 없다(그쪽 줄바꿈은 PTY와 앱이 정한다). **아직 설정 GUI에 뜨지 않는다** — 편집기가 제품 화면에 배선되기 전이라 이 값이 렌더에 닿는 경로가 없고, 그 상태로 토글을 노출하면 눌러도 아무 일이 없어 버그로 보인다. 이 파일로는 지금도 켤 수 있다 |
| `editor.tab-width` | `1`~`16` | `4` | 네이티브 파일 편집기에서 **탭 하나가 몇 칸인가**([설정](native-editor-ui.md) §9). 렌더의 탭스톱과 hit-test·마크 계산이 **같은 값**을 쓴다 — 갈리면 강조가 글자에서 밀린다. 기본 4는 VSCode·Zed와 같다. **상한 16의 근거**: 그 위는 한 탭이 화면 폭의 상당 부분을 먹어 본문이 안 보인다(VSCode는 상한을 안 두지만 그쪽은 워드랩·미니맵이 완충한다). 하한 1은 "탭을 한 칸으로"이고, 0은 탭스톱이 0이라 열이 안 늘어 뜻이 없다. 바꾸면 열려 있는 편집기에 **즉시 반영**되고 접힘은 펼쳐진다(탭 폭이 바뀌면 겹수가 달라져 어느 범위가 접혀 있었는지 대응되지 않는다 — 보던 줄은 지킨다) |
| `editor.cursor-shape` | `bar`\|`block`\|`underline` | `bar` | 네이티브 파일 편집기의 **커서(caret) 모양**. `bar`=폭 2px 막대(글자 **사이**에 선다), `block`=글자 한 칸을 채운다, `underline`=글자 밑에 두께 2px 밑선. **터미널 `cursor.shape`와 값 이름은 같지만 키는 따로다** — 그쪽은 *"앱이 `DECSCUSR`로 지정하지 않았을 때의 기본값"*이고 이쪽은 **그냥 그 모양**이다(편집기에는 모양을 지정할 앱이 없어 "기본값"과 "값"이 갈릴 자리가 없다). 키를 하나로 묶으면 터미널은 블록, 편집기는 막대로 쓰는 조합을 표현할 수 없다. **기본이 `bar`인 이유**(터미널 기본은 `block`): 터미널은 셀 격자 위에서 "어느 칸에 있는가"가 중요하고 편집기 커서는 글자 **사이**에 서기 때문이다 — VSCode·Zed·Vim insert 모드가 모두 막대다. `block`·`underline`은 **글자 폭을 덮는다**(한글·이모지는 두 칸). `block`이 선 칸의 글자는 **배경색으로** 그려진다 — 터미널이 커서 칸의 전경·배경을 맞바꾸는 것과 같고, 안 그러면 커서색 위에 원래 글자색이 남아 그 한 글자만 안 읽힌다. 깜빡임은 모양과 무관하게 기존 규칙을 따른다 |
| `sidebar.show-branch` | `true`\|`false` | `true` | 세로 사이드바 세션 카드에 git 브랜치명을 표시할지. 카드 이름줄은 식별용이라 항상 표시. 그 외 값은 무시. 사이드바 헤더 **view options(⚙) 메뉴**에서 토글하면 이 키에 양방향 반영(앱→config 파일 atomic write, 주석 보존) |
| `sidebar.show-folder` | `true`\|`false` | `true` | 위와 같되 폴더(cwd) 경로 줄(cwd가 git repo 안일 때만). 마찬가지로 view options(⚙) 메뉴에서 토글·양방향 |
| `sidebar.agent-hooks` | `true`\|`false` | `true` | provider 훅(claude `settings.json`, codex `hooks.json`)을 설치해 에이전트 **상태·알림·턴 변경분**을 훅에서 받는다 — 켜면 그 터미널은 화면·OSC를 읽는 관측 모드를 쓰지 않는다([agent-hooks.md](agent-hooks.md) §1: 두 모드는 섞이지 않는다). **끄면 지운다** — 켜고 끄기가 한 쌍이라 되돌릴 수 있다. 지우는 것은 우리 표식(`MARU_HOOK_V3`)이 붙은 항목뿐이고, codex 는 `config.toml` 의 신뢰 블록도 함께 거둔다(우리 표식이 붙은 것만 — 사용자가 직접 승인한 항목은 건드리지 않는다). 우리가 넣은 항목은 커맨드 안의 표식으로 식별되고, 표식이 없는 사용자 항목은 순서까지 보존한다. 옛 상태줄 훅(`sidebar.agent-transcript-hook`)은 **없어졌다** — 그것이 하던 일(세션 신원 하나)이 `SessionStart`의 부분집합이라, 사용자 `statusLine`을 감싸던 침습을 지웠다([agent-hooks.md](agent-hooks.md) §5). 앱은 시작할 때 그 설치물을 거두기만 한다. **기본이 켜짐이다**(2026-08-22) — 비용을 재고(훅 1회 10.39 ms, 스크립트 몫은 측정 한계 아래) 양 provider 대화형에서 배지·알림이 실제로 도는 것을 확인한 뒤 전환했다. ⚠️ 켜면 **사용자의 provider 설정 파일을 고친다**. 끄면 되돌아간다. ⚠️ codex 의 오류 턴은 미검증이라(`StopFailure` 가 없다) 그때 배지가 안 풀릴 수 있고, 그러면 이 키를 끄는 것이 즉시 회피책이다 |
| `sidebar.width` | 정수(120~480) | `180` | 세로 사이드바 폭(논리 pt, DPI 스케일). 사이드바 우측 경계를 드래그하면 이 키에 양방향 반영(드래그 종료 시 앱→config 파일 atomic write, 주석 보존). 범위 밖/비정수는 무시(기본 유지). 런타임은 헤더 아이콘(신호등·⚙ 등)이 겹치지 않게 폰트 크기에 비례한 **동적 하한**으로 다시 끌어올릴 수 있어, 작은 값을 저장해도 실제 폭은 그 하한 이상이 된다 |
| `term` | 문자열 | `xterm-maru` | 셸에 줄 `$TERM`(컴파일 실패 시 `xterm-256color` 폴백). 아래 참조 |
| `shell-integration.ssh` | `true`\|`false` | `false` | 평범한 `ssh`를 `maru ssh`로 라우팅해 원격에 `xterm-maru` terminfo를 전파할지(opt-in). 기본 off(다운그레이드로 원격 안 깨짐). [셸 통합 ssh 라우팅](configuration-shell.md#셸-통합-ssh-라우팅-shell-integrationssh) 참조 |
| `ssh.server-alive-interval` | 정수(0~3600) | `15` | `maru ssh` 세션에 붙일 `ServerAliveInterval`(초). `server-alive-count-max`와 곱해 **45초 안에** 죽은 연결을 감지한다. **`0`이면 `-o`를 아예 안 붙인다** — ssh는 커맨드라인 `-o`가 설정 파일보다 우선이라, 값을 고정해 붙이면 사용자 `~/.ssh/config`의 `ServerAlive*`를 말없이 덮기 때문이다. 평범한 `ssh`는 건드리지 않는다. [끊김 감지와 재접속](configuration-shell.md#maru-ssh-끊김-감지와-재접속-ssh) 참조 |
| `ssh.server-alive-count-max` | 정수(1~10) | `3` | 응답 없는 keepalive를 몇 번까지 견딜지(`ServerAliveCountMax`). `server-alive-interval`이 `0`이면 안 쓰인다. 하한이 1인 이유는 ssh에서 0이 "즉시 끊어라"라 오작동에 가깝기 때문이다 |
| `ssh.reconnect` | `true`\|`false` | `true` | `maru ssh` 세션이 끊기면(ssh exit 255) 자동으로 다시 붙을지. 1→2→4→8→16→30초 백오프, 대기 중 Enter로 즉시·Ctrl-C로 중단. 원격 command를 붙인 호출(`maru ssh host ls`)과 접속 자체가 안 되는 호스트는 대상이 아니다. **재접속은 새 세션이다** — SSH에 재개가 없어 끊긴 시점의 원격 셸은 돌아오지 않는다(원격 세션 호스트·tmux가 있을 때만 이어진다) |
| `env.<KEY>` | 문자열 | (없음) | 새 셸에 주입할 환경변수(`env.EDITOR = nvim`처럼 여러 줄). 부모 상속 env + maru override(TERM 등) **위에 upsert** — 같은 KEY면 덮어쓰고 없으면 추가("부모 + 사용자"). 단 control-plane selector `MARU_PANE_ID`는 spawn 값이 최종 우선한다. 값은 양끝만 trim(내부 공백 보존), 빈 값 허용. 빈 KEY(`env. =`)는 무시. 새로 여는 셸에만 적용(reload는 기존 셸 env 안 바꿈). 아래 참조 |
| `shell.command` | 경로 | (없음) | 대화형 셸 실행 파일 경로(절대경로). 비어 있으면(기본) `$MARU_INTERACTIVE_SHELL`→`$SHELL`→`/bin/sh` 순으로 자동 결정(현행). 새로 여는 셸에만 적용. 아래 참조 |
| `shell.args` | 문자열 | POSIX `-i` / **Windows 없음** | 셸 인자(argv, command 제외). 공백으로 토큰 분리(`shell.args = -i -l`). 따옴표 미지원. 빈 값(`shell.args =`)이면 인자 없음. **기본값이 OS 마다 다르다** — POSIX 의 `/bin/sh` 는 `-i` 가 있어야 대화형으로 서지만 Windows 의 pwsh·cmd 는 콘솔에 붙는 순간 이미 대화형이고, PowerShell 5.1 은 `-i` 를 `-InputFormat` 축약으로 읽어 **셸이 안 뜬다**. 아래 참조 |
| `shell.windows-shell` | `pwsh`\|`powershell`\|`cmd` | `pwsh` | **Windows 전용.** 설정 GUI 에는 노출하지 않는다(파일 전용). 기본으로 띄울 셸 **종류**. `shell.command` 가 비어 있을 때만 본다(명시 경로가 더 구체적이라 그쪽이 이긴다). `pwsh` 는 **PowerShell 7** 을 먼저, `powershell` 은 **Windows PowerShell 5.1** 을 먼저 보고, 없으면 서로에게 내려간다(고정이 아니라 **선호** — 고정하려면 `shell.command` 로 경로를 못 박는다). `cmd` 는 `cmd.exe` 를 곧장 쓴다. **둘을 가르는 이유**는 5.1 과 7 이 같은 셸의 버전 차이가 아니라 **매개변수 집합이 다른 별개 프로그램**이기 때문이다(실측: `-i` 를 5.1 은 `-InputFormat` 축약으로 읽고 값을 요구해 안 뜬다). 경로가 아니라 종류를 고르는 이유는 실제 경로가 기기마다 다르기 때문이다. 다른 OS 에서는 읽히되 쓰이지 않는다(dotfiles 공유 시 diagnostic 이 안 뜨게). 아래 참조 |
| `keybind` | `<조합> = <action>` | (없음) | 여러 줄 가능. 아래 참조 |

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
