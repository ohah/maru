# 설정 — 텍스트와 테마

컬러 테마 프리셋과 문자 폭 판정의 배경이다. `theme.preset`·`text.ambiguous-width`·`text.emoji-width`가 왜 그 기본값인지, 값마다 무엇이 달라지는지 적는다.

> 키 표와 파일 형식은 [설정(config) 파일](configuration.md)이 소유한다. 키별 배경은 [텍스트·테마](configuration-text.md) · [입력·키바인딩](configuration-input.md) · [셸·환경](configuration-shell.md)로 나뉜다.

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
>   마찬가지다. 이를 런타임에 읽히게 하는 안전장치가 [`theme.min-contrast`](configuration.md#키)(기본 `3.0`)다 — 전경이 배경
>   대비 그 명암비에 못 미치면 색상을 보존한 채 최소한만 보정한다(밝은 배경=어둡게, 어두운 배경=밝게). **프리셋 상수(파일의 원색 세트)는 손대지 않고
>   렌더 시점 해석에서만 하한을 적용**하므로 "스킴 표준값 보존"과 "가독성"이 양립한다(특히 `one-light`의 안 보이는
>   bright-white `#ffffff`·밝은 yellow처럼 업스트림 자체가 저대비인 경우를 교정). `0`으로 끄면 업스트림 원색 그대로다.
>   **팔레트 선보정**(ANSI 16색)은 어둡게만 하므로 다크 프리셋에선 무동작이다(그 팔레트가 ANSI 배경색·OSC 4 응답으로도
>   나가기 때문 — 밝히면 배경이 뜬다). 다크 배경에서 안 보이는 **전경**(라이트 전용 배색을 truecolor로 하드코딩한
>   프로그램)은 렌더 per-cell 하한이 밝히는 방향으로 교정한다 — 단 번들 테마 팔레트·powerline·faint를 건드리지 않도록
>   **좁게** 적용한다(조건은 위 키 표).
>
> 색 룩만 정한다. chrome 쪽 축(`chrome.tab-style`)과는 직교다.

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

- `wide` (기본): 두 칸(advance 2). **모던 TUI가 쓰는 string-width 라이브러리**가 이모지(키캡 포함)를 2칸으로
  세므로 거기에 맞춘다 — 이모지가 풀사이즈로 또렷하게 나오고, 2칸을 예약하는 TUI(예: Claude Code) 레이아웃과도
  정합한다(1칸만 그리면 작은 이모지 + 옆 빈틈이 생긴다).
- `narrow` (opt-in): 한 칸(advance 1, EAW 그대로). **zsh ZLE 등이 base+VS16을 1칸으로 가정**하는 환경에서 셸 줄
  편집(커서·재출력)이 어긋나는 게 더 거슬릴 때 끈다. 이모지는 작게 나오지만 1칸 가정 프로그램과 정렬이 보존된다.

`grapheme cluster mode`(DECSET 2027)를 켜는 앱과는 이 설정과 무관하게 항상 2칸이다(앱이 너비를 합의한 상태).
적용 대상은 VS16 이모지 표현과 키캡이며, 스킨톤·국기(지역 표시자 페어)는 mode 2027에서만 한 글자로 묶는다(별도 동작).

> 베이스/결정: **여기서 maru 는 레퍼런스와 반대로 간다.** 소스로 확인한 바로는 Ghostty 도 xterm.js 도 **합의 전에는
> 1칸**이다 — Ghostty 는 mode 2027 이 꺼져 있으면 VS16 을 셀에 붙이되 폭은 안 올리고(`Terminal.zig` 의
> "VS16 doesn't make character wide with 2027 disabled" 테스트가 `Cell.Wide.narrow` 를 단언한다), xterm.js 는
> `addon-unicode-graphemes` 를 붙인 임베더에서만 VS16 을 2칸으로 센다. 즉 둘 다 **앱/임베더가 합의해야** 2칸이다.
> (iTerm2·kitty 는 소스를 안 봤으므로 근거로 들지 않는다.)
>
> maru 가 기본을 뒤집은 근거는 터미널 쪽이 아니라 **앱 쪽**이다 — 모던 TUI 가 쓰는 string-width 라이브러리가 이모지를
> 2칸으로 세므로, 합의 프로토콜(2027)을 안 켜는 그 TUI 들과 화면이 어긋난다. 1칸으로 두면 이모지가 작게 나오고 옆에
> 빈틈이 생긴다. `narrow` 는 1칸을 가정하는 셸 줄 편집과의 정렬을 우선하려는 opt-out 이다(`ambiguous-width` 와 같은
> 트레이드오프 구조 — 표시 정확 ↔ 1칸 가정 프로그램과의 정렬).
>
> **이 선택의 대가는 명시해 둔다**: 합의 없이 폭을 올리므로 상대가 1칸으로 세면 그만큼 어긋난다. 그래서 opt-out 이 있다.
