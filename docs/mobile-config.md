# 모바일 config

모바일 앱이 읽는 설정의 **스키마·파일 위치·읽고 쓰는 경로**의 단일 출처다. 데스크톱 config 계약은
[설정](configuration.md)이 소유하고, 이 문서는 **모바일 것만** 소유한다. 화면의 생김새는
[모바일 UX §5.6](mobile-ux.md)이, 플랫폼 경계는 [모바일 플랫폼](mobile-platform.md)이 소유한다.

## 1. 데스크톱과 파일도 스키마도 나눈다

**값은 안 나누고 기계를 나눈다** — 거꾸로가 아니다. 파서·resolve 규율·"파일이 단일 출처" 원칙은
`src/config` 를 그대로 쓰고, **무엇을 실을지와 어디에 둘지만** 모바일 것으로 둔다.

데스크톱 키를 전부 훑으면 왜 나눠야 하는지가 드러난다. `quick-terminal.*`·`shell.command`·
`input.option-as-meta`·`window.*` 처럼 **모바일에 뜻이 없는 것**이 큰 덩어리이고, 반대로
모바일에만 필요한 것(보조 키바 구성·터치·전력·원격 접속 프로필)은 데스크톱 스키마에 아예 없다.
합치면 양쪽 다 쓰지 않는 키를 이고 간다.

**원격 세션에 붙어도 PC 의 config 를 끌어오지 않는다.** 화면 크기·입력 방식·전력 사정이 다른
기기의 값을 베끼면 대부분 틀린다.

## 2. 어디에 두나

**앱 전용 자리다**(사용자 확정). 사용자도 다른 앱도 못 본다.

| | 경로 |
|---|---|
| iOS | `Library/Application Support/maru/config` |
| Android | `filesDir/config` (`/data/data/<pkg>/files/config`) |

- **추가 선언이 없다.** iOS 의 `UIFileSharingEnabled` 도, Android 의 저장소 권한도 필요 없다.
- **iOS 는 그 디렉터리를 앱이 만들어야 한다.** 새 컨테이너의 `Library` 에는 `Caches` 와
  `Preferences` 뿐이다(시뮬레이터 컨테이너로 확인) — `Application Support` 는 없다. 없는 채로
  쓰면 저장이 실패하고, §6 이 "쓰기가 실패하면 조용하지 않다" 를 요구하므로 **만들지 못한 것도
  실패로 알린다**. Android 의 `filesDir` 은 항상 있다.
- **`Library/Caches` 에 두지 않는다.** OS 가 저장 공간이 모자라면 지우는 자리다 — 설정이
  말없이 초기화된다.
- **앱을 지우면 같이 사라진다.** 그것이 이 자리의 뜻이다 — 남기려면 내보내기가 있어야 하고,
  그건 이 계약 밖이다.
- **손으로 고치는 길은 없다.** 데스크톱은 파일을 편집기로 여는 것이 정상 경로지만 폰에는 그
  편집기가 없다. 그래서 **설정 화면이 유일한 입력 경로**이고, 파일은 그 화면이 쓰는 저장소다.
  "파일이 단일 출처" 는 그대로다 — 화면이 상태를 따로 들지 않는다는 뜻이라 여전히 유효하다.

## 3. 형식은 데스크톱과 같다

`key = value` 한 줄에 하나, `#` 주석. **파일 형식을 새로 만들지 않는다** — 같은 파서가
읽으므로 형식이 갈릴 이유가 없고, 갈리면 두 문법을 유지해야 한다.

기계는 이렇게 나뉜다.

| 무엇 | 어디 |
|---|---|
| 줄 문법(`key = value`·주석·`=` 없는 줄 진단) | **공유** — `src/config/loader.zig` |
| 키→필드 파싱·직렬화 | **공유** — `src/config/schema.zig` 의 comptime 스키마 엔진 |
| 부분 갱신(주석·모르는 키 보존) | **공유** — `loader.updateConfigText` (텍스트 + 키/값 쌍만 받는다) |
| 어떤 키가 있고 기본값이 무엇인가 | **모바일 것** — 이 문서 §4 |
| 파일 위치 | **모바일 것** — 위 §2 |

**엔진을 공유하려면 데스크톱 구조체에 박힌 자리를 열어야 한다.** 파라미터 하나가 아니라
**본문의 반영(reflection) 대상까지** 같이 연다 — `schema.tryParse` 는 파라미터(`*theme.Config`)
외에 본문에서도 `@hasDecl(theme.Config, ...)`·`@typeInfo(theme.Config)` 로 **그 타입을 직접 부른다**.
받는 타입을 `anytype` 으로 열고 그 반영들을 파라미터의 타입으로 바꾸면 모바일 구조체가 자기
`schema` 메타를 들고 같은 엔진을 탄다. **데스크톱 동작은 안 바뀐다**(같은 함수에 같은 타입을
계속 넘긴다).

**쓰는 쪽은 더 묶여 있다.** `serialize.updateForKeys` → `configKeyValues` → `schema.appendSerialized`
가 **셋 다** `theme.Config` 를 받는다. 그래서 모바일이 그대로 부를 수 있는 것은 그 아래의
`loader.updateConfigText`(Config 를 모른다) 이고, 그 위는 **모바일 구조체용으로 같은 모양을
한 벌 세우거나** 위와 같은 방식으로 열어야 한다. 어느 쪽이든 **부분 갱신 규율은 하나**다.

## 4. 무엇을 싣나

키를 고르는 기준은 하나다 — **그 값을 지금 소비하는 자리가 코드에 있는가.** 없는 키를 미리
실으면 사용자가 바꿔도 아무 일이 안 일어난다(그게 지금 설정 화면의 상태다).

### 4.1 지금 싣는다

| 키 | 뜻 | 데스크톱과 다른 점 |
|---|---|---|
| `font.size` | 본문 글자 크기 | **굽는 크기와 함께 움직여야 한다** — 아래 §5 |
| `font.line-height` | 줄 높이 배수 | 같음 |
| `theme.preset`·`theme.preset-dark`·`theme.preset-light` | 색 묶음 | 같음 |
| `theme.follow-system` | 다크/라이트를 OS 에 맞춘다 | 모바일에서 **더 중요하다** — OS 전역 토글이 흔하다 |
| `theme.background`·`foreground`·`cursor`·`selection`·`palette.N` | 개별 색 | 같음 |
| `theme.bold-is-bright`·`theme.min-contrast` | 색 규칙 | 같음 |
| `cursor.shape`·`cursor.color`·`cursor.text`·`cursor.blink`·`cursor.blink-interval-ms`·`cursor.blink-fade-ms` | 커서 | 같음 |
| `text.ambiguous-width`·`text.emoji-width` | 폭 규칙 | 같음(코어 축) |
| `scrollback.lines` | 스크롤백 줄 수 | **기본값이 다르다** — §4.4 |
| `render.frame-rate` | 프레임 주기 | **상한이 기기에 달렸다** — §5 |
| `input.word-separators` | 단어 경계 | **길게 눌러 단어를 잡는** 그 판정이 이 값을 쓴다 |
| `input.selection-clear-on-typing` | 타이핑하면 선택 해제 | 같음 |
| `input.paste-protection`·`input.bracketed-paste-is-safe` | 붙여넣기 보호 | 같음 |
| `input.ime-enter`·`input.shift-enter` | Enter 처리 | 소프트 키보드 Return 이 같은 경로를 탄다 |
| `osc52.read` | 클립보드 읽기 정책 | 같음(기본 `deny`) |
| `bell.audible`·`bell.visual` | 벨 | `bell.dock-badge` 는 안 가져온다(dock 이 없다) |

### 4.2 모바일에만 있는 키

데스크톱에 대응이 없다. 이름은 **모바일 것**이므로 데스크톱 이름을 억지로 빌리지 않는다.

| 키 | 뜻 |
|---|---|
| `keybar.keys` | 보조 키바에 어떤 키를 어떤 순서로 둘지 |
| `power.low-power-frame-rate` | 저전력 모드에서 낮출 주기 |

**길게 누름 지연은 config 에 안 둔다.** OS 접근성 설정이 소유하고 host 가 매번 읽어 넘긴다
([플랫폼 §3.1](mobile-platform.md)) — config 로 덮으면 그 설정을 무시하게 된다.

### 4.3 안 가져오는 것과 그 이유

| 키 | 왜 |
|---|---|
| `shell.command`·`shell.args`·`shell-integration.ssh`·`session.keep-alive-after-quit`·`workspace.*` | **로컬 PTY 가 없다**([플랫폼 §1](mobile-platform.md)). 세션은 원격에서 받는다 |
| `quick-terminal.*`·`window.*`·`split.*`·`sidebar.*`·`status-bar.show`·`chrome.preset`·`chrome.tab-style` | 데스크톱 창·크롬 개념이다. 폰에는 창이 하나고 배치가 다르다([UX §3](mobile-ux.md)) |
| `input.option-as-meta`·`input.right-click`·`input.mouse-hide-while-typing`·`input.url-click-modifier` | 마우스와 맥 키보드 축이다 |
| `keyhint.*`·`keybind` | 하드웨어 키보드 축이다. 폰의 기본 입력은 소프트 키보드와 보조 키바다 |
| `font.family`·`font.family-bold`·`font.family-italic`·`font.fallback` | 폰트를 **번들이 정한다**. 시스템 폴백은 host 가 하고 사용자가 파일을 넣을 자리가 없다 |
| `editor.wrap`·`file-panel.external-link-target` | 그 화면이 모바일에 없다 |
| `notifications.update-check` | 스토어가 한다 |
| `theme.palette` 이외의 `chrome.theme` | 색 축은 `theme.*` 하나로 둔다. 두 이름이 같은 것을 정하면 어느 쪽이 이기는지 사용자가 모른다 |

### 4.4 기본값이 데스크톱과 다른 것

**같은 키라도 기기가 다르면 기본값이 다르다.** 이것을 안 적으면 "왜 폰에서만 다르지" 가 된다.

| 키 | 데스크톱 | 모바일 | 왜 |
|---|---|---|---|
| `scrollback.lines` | 1000 | 더 작게 | 기기 메모리가 다르다. 셀 하나가 몇 바이트인지는 같아도 여유가 다르다 |
| `render.frame-rate` | 화면 주사율 | 30 | 전력이 예산이다([플랫폼 §3.2](mobile-platform.md)) |

## 5. 지금 열 수 없는 것과 그 이유

- **`font.size` 를 여는 것은 글리프 기하와 한 몸이다.** 굽는 크기(`MARU_ATLAS_TEXT_PX`)와 그리는
  크기가 지금 따로 논다. 크기를 config 로 열면 그 어긋남이 곧 사용자에게 드러나므로, 이 키는
  **굽는 크기까지 함께 움직이는 슬라이스**에서만 연다.
- **`render.frame-rate` 의 상한은 config 가 못 올린다.** iOS 는 `CADisableMinimumFrameDuration`
  이 **번들에 박히는 능력 선언**이라 없으면 ProMotion 기기에서 조용히 60 으로 잘린다
  ([플랫폼 §3.2](mobile-platform.md)). 값을 여는 슬라이스는 그 키가 제품 번들에 있는지부터 본다.
- **원격 접속 프로필(호스트·인증)은 이 계약 밖이다.** 전송·인증이 정해져야 형태가 나온다
  ([계획 M3a](plans/mobile-platform.md)). **자격증명은 이 파일에 안 쓴다** — Keychain·Keystore 가
  그 자리이고, config 에는 그것을 가리키는 이름만 둔다.

## 6. 읽고 쓰는 경로

**브리지엔 OS 호출이 없다**([플랫폼 §3](mobile-platform.md)). 파일을 여는 것은 host 이고 브리지는
바이트만 받는다 — 클립보드·알림과 같은 경계다.

```
읽기:  host 가 §2 경로를 읽어 바이트를 넘긴다 → 브리지가 파싱해 들고 있는다
쓰기:  설정 화면이 값을 바꾸면 브리지가 **바뀐 키만** 반영한 새 본문을 만든다
       → host 가 그 바이트를 같은 경로에 쓴다
```

- **부분 갱신이다**(`loader.updateConfigText` — §3). 통째로 다시 쓰면 주석과 **모르는 키**가 사라진다.
- **파일이 없어도 앱은 뜬다.** 없음·권한·크기 초과는 전부 기본값으로 간다(데스크톱과 같은
  forgiving 규율). 설정을 한 번도 안 건드린 기기가 정상 상태다.
- **모르는 키는 무시하되 지우지 않는다.** 앱을 되돌려 깐 기기에서 새 키가 사라지면 안 된다.
- **쓰기가 실패하면 조용하지 않다** — 화면은 이미 바뀌었는데 다음에 켜면 돌아가 있으면
  사용자는 이유를 모른다.

## 7. 이 계약 밖

- **내보내기·가져오기** — 앱을 지우면 설정이 사라지는 것의 짝이다. 필요해지면 그때 정한다.
- **원격에서 설정을 밀어 넣기** — PC 의 config 를 안 끌어온다는 §1 과 정면으로 부딪히므로,
  하려면 그 결정을 먼저 뒤집어야 한다.
- **기기 간 동기화**(iCloud·Google 백업) — 자격증명 경계(§5)와 함께 정해야 한다.
