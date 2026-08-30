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
  쓰면 저장이 실패하고, §7 이 "쓰기가 실패하면 조용하지 않다" 를 요구하므로 **만들지 못한 것도
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
| 줄 문법(`key = value`·주석·`=` 없는 줄 진단) | **규칙만 같다** — `loader.parse` 는 못 부른다(데스크톱 Config 에 박혀 있고 keybind 4종·env 목록까지 만든다). 모바일이 같은 규칙으로 짧은 루프를 둔다 |
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

**엔진 밖에 있는 키가 둘 있다.** `theme.preset`(색 묶음을 통째로 깐다)과 `theme.palette.N`(인덱스
키)은 스키마가 아니라 `loader.applyKey` 의 **명시 가지**가 처리한다(계약 문서가 "동적·특수" 로
분류해 둔 것들이다). 그래서 그 둘은 `tryParse` 를 열어도 안 따라온다 — 모바일이 같은 짧은 가지를
자기 쪽에 두거나, 아래 "빌려 조립" 을 택해야 한다.

**구조체를 새로 쓸지, 빌려 조립할지가 갈림길이다.** sub-struct 가 전부 이름 있는 공개 타입이라
(`FontConfig`·`ThemeConfig`·`CursorConfig`·`InputConfig`) 모바일 Config 가 그것들을 **필드로 빌려**
조립할 수 있다.

| | 빌려 조립 | 새로 쓰기 |
|---|---|---|
| 스키마 메타 | **대부분** 안 쓴다 — 다만 `theme.follow-system`·`preset-dark`·`preset-light` 는 색 세트가 아니라 **선택 정책**이라 `Config` 직속이다. 빌려도 안 따라오므로 모바일이 직접 단다 | 키마다 다시 단다 |
| `theme.preset` | `presetColors()` 가 **바로 그 타입**을 돌려줘 그대로 대입된다 | 반환형이 달라 못 쓴다 |
| 섹션(GUI) | **안 따라온다** — 아래 |
| 대가 | **모바일에 뜻 없는 필드가 딸려온다** — `InputConfig` 13개 중 12개, `ThemeConfig` 의 `sidebar_*`·`search_match*`. §4.4 가 "안 가져온다" 고 적은 키를 **파일에서 받아들이게 된다**(해는 없다 — 소비처가 없으니 무동작이다. 다만 문서와 코드가 갈린다) | 키 표면이 문서와 정확히 같다 |

**섹션은 어느 쪽을 택하든 모바일이 소유한다.** 빌려도 공짜로 안 따라온다 — 두 분류가 **부분집합이
아니라 다른 체계**다. 데스크톱 `Section` 은 config 이름 공간에 가깝고(`bell` 계열 이 `.terminal` 을 단다)
모바일 화면은 사용자가 찾는 주제로 묶는다([UX §5.6](mobile-ux.md) 확정: 모양·글자·커서·터미널·
입력·알림·화면·모바일). 여덟 중 **알림·화면·모바일 셋이 데스크톱에 대응이 없고**, 특히 "알림" 은
모바일 전용 개념이라서가 아니라 **묶는 기준이 달라서** 없다. 그래서 빌리는 것은 **파싱**이지
**배치**가 아니다.

**계열마다 따로 정한다.** 통째로 뜻이 있는 것(`ThemeConfig`·`CursorConfig`)은 빌리고, 한 조각만
필요한 것(`input` 은 `word-separators` 하나)은 모바일 것으로 둔다 — 그래야 §4.4 의 "안 가져온다"
가 코드에서도 참이 된다.

**쓰는 쪽은 더 묶여 있다.** `serialize.updateForKeys` → `configKeyValues` → `schema.appendSerialized`
가 **셋 다** `theme.Config` 를 받는다. 그래서 모바일이 그대로 부를 수 있는 것은 그 아래의
`loader.updateConfigText`(Config 를 모른다) 이고, 그 위는 **모바일 구조체용으로 같은 모양을
한 벌 세우거나** 위와 같은 방식으로 열어야 한다. 어느 쪽이든 **부분 갱신 규율은 하나**다.

## 4. 무엇을 싣나

키를 고르는 기준은 하나다 — **그 값을 지금 소비하는 자리가 코드에 있는가.** 없는 키를 미리
실으면 사용자가 바꿔도 아무 일이 안 일어난다(그게 지금 설정 화면의 상태다).

### 4.1 지금 싣는다 — 소비처를 코드에서 확인한 것만

**"소비처가 있다" 를 눈으로 확인하고 넣었다.** 아래 표의 "소비처" 열이 그 근거다 — 없는 키를
실으면 사용자가 바꿔도 아무 일이 안 일어난다.

| 키 | 소비처 | 비고 |
|---|---|---|
| `theme.preset` | 브리지 `themeColors()` | 파싱은 **스키마 밖**이다(§3) — `loader.applyKey` 의 명시 가지 |
| `theme.background`·`theme.foreground`·`theme.cursor`·`theme.selection`·`theme.palette.0`~`.15` | 같음 | 팔레트는 계열 키다 |
| `theme.bold-is-bright`·`theme.min-contrast` | 같음 | |
| `cursor.color`·`cursor.text` | 브리지 커서 quad(`tk.get(.cursor)`) | |
| `cursor.shape` | 코어(`snap.cursor_shape`) | config 는 **기본 모양**을 준다. TUI 가 DECSCUSR 로 바꾸면 그쪽이 이긴다 |
| `text.ambiguous-width` | 코어 `ambiguous_wide` | 브리지가 코어에 세워 주면 된다 |
| `text.emoji-width` | 코어 `emoji_wide` | `ambiguous_wide` 와 같은 모양 — 앱 계층이 세운다 |
| `scrollback.lines` | 코어 `setMaxScrollback` | 기본값은 §4.5 |
| `input.word-separators` | 코어 `selectWordAt(…, separator_bytes)` | **지금 호출부가 빈 목록(`&.{}`)을 넘긴다** — M10b 가 그 자리를 잇는다 |
| `osc52.read` | 코어 | `deny`(기본)는 지금도 지켜진다. `allow` 는 host 가 클립보드를 **읽는** 경로가 있어야 하는데 지금은 쓰기(`take_copy`)뿐이다 |

### 4.2 스키마에 두되 소비처가 생길 때 연다

**여기 있는 키는 "모바일에 뜻이 없어서" 가 아니라 "아직 그 일을 하는 코드가 없어서" 빠졌다.**
그 코드가 생기는 슬라이스에서 함께 연다.

| 키 | 지금 없는 것 |
|---|---|
| `font.size`·`font.line-height` | 굽는 크기(`MARU_ATLAS_TEXT_PX`)와 그리는 크기가 따로 논다 — §5, [M10d](plans/mobile-platform.md) |
| `render.frame-rate` | 값은 30 고정이고 **상한은 번들 능력 선언**이 정한다 — §5 |
| `cursor.blink`·`cursor.blink-interval-ms`·`cursor.blink-fade-ms` | 모바일은 커서를 **깜빡이지 않는다**(정적 quad) |
| `input.paste-protection`·`input.bracketed-paste-is-safe` | **붙여넣기 경로가 없다**. 지금 "paste" 는 설정 화면 라벨뿐이다 |
| `input.ime-enter`·`input.shift-enter`·`input.selection-clear-on-typing` | 데스크톱 앱 계층(`platform/macos/app_session`)이 소비한다. 모바일의 대응 자리는 브리지이고 아직 그 처리가 없다 |
| `bell.audible`·`bell.visual` | 벨 처리가 없다. 지금 "bell" 은 chrome 헤더 **아이콘**뿐이다 |
| `theme.follow-system`·`theme.preset-dark`·`theme.preset-light` | **OS 외관을 받는 경로가 없다** — 브리지·두 host·ABI 어디에도 라이트/다크를 알리는 자리가 없다. 값만 실으면 켜도 아무 일이 안 난다. ABI 를 하나 여는 슬라이스에서 함께 연다(iOS `traitCollection`·Android `uiMode`) |
| `text.blink` | 깜빡임을 안 그린다(SGR 5 는 정적 — 코어도 "렌더는 정적" 이라고 적어 뒀다) |
| `ui.language` | **OS 로케일을 받는 경로가 없다** — 브리지·두 host·ABI 어디에도 로케일을 알리는 자리가 없다(macOS 는 `maru_macos_app_set_ui_locale` 로 Swift 가 넣는다). 기본값이 `auto` 라 그 자리가 없으면 영어로 떨어지고, `ko` 로 명시해도 적용할 호출부(`applyPreference`)가 없다. `theme.follow-system` 과 **같은 모양의 구멍**이라 OS 상태를 알리는 ABI 를 여는 슬라이스에서 함께 연다(iOS `Locale.preferredLanguages`·Android `LocaleList`). 모바일 자체 UI 문자열은 [다국어](i18n.md) I3e 가 키로 옮긴다 |
| `input.link-detection`·`input.link-open-target` | 링크를 눌러 여는 경로가 없다 |
| `input.page-keys` | 키바에 PageUp/Down 키캡은 있지만 이 정책을 보는 자리가 없다 |
| `notifications.osc`·`notifications.history-limit` | 알림을 받는 자리도 목록도 없다 |
| `scrollback.sticky-command` | 그 chrome 표시가 모바일에 없다 |
| `font.letter-spacing` | 자간을 조절하는 자리가 없다(글리프를 칸에 맞춰 그린다) |
| `term` | `TERM` 문자열은 **세션을 만드는 쪽**이 정한다 — 모바일은 원격에서 받는다([M3a](plans/mobile-platform.md)) |

### 4.3 모바일에만 있는 키

데스크톱에 대응이 없다. 이름은 **모바일 것**이므로 데스크톱 이름을 억지로 빌리지 않는다.

| 키 | 뜻 |
|---|---|
| `keybar.keys` | 보조 키바에 어떤 키를 어떤 순서로 둘지 |
| `power.low-power-frame-rate` | 저전력 모드에서 낮출 주기 |
| `ssh.server.<n>.name` | 목록에 보일 이름. 비면 화면이 `user@host` 로 보인다 |
| `ssh.server.<n>.host` | 주소(이름 또는 IP) |
| `ssh.server.<n>.port` | 포트. 없으면 22 |
| `ssh.server.<n>.user` | 로그인 이름 |
| `ssh.server.<n>.fingerprint` | 호스트키 지문(`SHA256:...`). **비워 둘 수 있다** — 처음 붙을 때 화면이 서버가 내민 지문을 보여 주고 묻는다. 승인하면 **이 줄에 적힌다**([SSH 계약](ssh-client.md) §3.4) |

**서버 목록은 인덱스 키다**(`theme.palette.N` 과 같은 부류 — 스키마 엔진 밖의 명시 가지다).
한 줄에 레코드를 통째로 적는 문법을 새로 만들지 않는다: 값이 스칼라라야 §3 의 부분 갱신
(`updateConfigText`)이 **필드 하나만** 고칠 수 있고, 파일을 눈으로 읽을 때도 무엇이 무엇인지
보인다.

- **저장은 목록을 통째로 다시 적는 일이다**(`withServers`). 값 하나만 고치는 방식으로는 지우기와
  번호 다시 매기기를 못 하고, 반쯤 지워진 줄이 남으면 다음에 읽을 때 없는 서버가 되살아난다.
  `ssh.server.*` 줄만 걷어내고 나머지(주석·모르는 키)는 그대로 둔다.
- **번호는 1부터**, 화면이 쓸 때 **빈 자리 없이 다시 매긴다**. 파일에 1·3 만 있으면 읽을 때
  둘로 좁혀 읽고, 다음 저장에서 1·2 가 된다. 번호는 이름이 아니라 순서다.
- **상한은 16개**다(`MARU_MAX_SERVERS`). 자리를 미리 잡아 두므로(브리지엔 할당이 없다)
  숫자가 곧 상주 메모리다. 넘는 번호는 무시한다.
- **주소와 사용자가 있어야 접속 대상이다.** 하나라도 비면 목록에는 보이되 접속은 거절한다 —
  반쯤 적은 줄로 붙으러 가면 실패 이유가 "네트워크" 처럼 보인다. **지문은 빼고 본다**: 처음
  붙는 서버는 없는 것이 정상이고 그때 화면이 묻는다(예전에는 필수라서 **지문을 미리 아는
  사람만** 붙을 수 있었다).
- **자격증명은 여기 없다**(§5). 개인키는 Keystore(Android)·앱 전용 파일(iOS, 임시 — [SSH 계획]
  (plans/ssh-client.md) S9c-2)에 있고, config 는 그것을 가리키지도 않는다. 기기가 가진 키는
  하나이기 때문이다.

**길게 누름 지연은 config 에 안 둔다.** OS 접근성 설정이 소유하고 host 가 매번 읽어 넘긴다
([플랫폼 §3.1](mobile-platform.md)) — config 로 덮으면 그 설정을 무시하게 된다.

### 4.4 안 가져오는 것과 그 이유

| 키 | 왜 |
|---|---|
| `shell.command`·`shell.args`·`shell.windows-shell`·`shell-integration.ssh`·`session.keep-alive-after-quit`·`workspace.*` | **로컬 PTY 가 없다**([플랫폼 §1](mobile-platform.md)). 세션은 원격에서 받는다. `shell.windows-shell`은 그 위에 Windows 전용이기까지 하다 |
| `quick-terminal.*`·`window.*`·`split.*`·`sidebar.*`·`status-bar.show`·`chrome.tab-style` | 데스크톱 창·크롬 개념이다. 폰에는 창이 하나고 배치가 다르다([UX §3](mobile-ux.md)) |
| `input.option-as-meta`·`input.right-click`·`input.mouse-hide-while-typing`·`input.url-click-modifier` | 마우스와 맥 키보드 축이다 |
| `keyhint.*`·`keybind` | 하드웨어 키보드 축이다. 폰의 기본 입력은 소프트 키보드와 보조 키바다 |
| `font.family`·`font.family-bold`·`font.family-italic`·`font.fallback` | 폰트를 **번들이 정한다**. 시스템 폴백은 host 가 하고 사용자가 파일을 넣을 자리가 없다 |
| `editor.wrap`·`editor.tab-width`·`editor.cursor-shape`·`file-panel.external-link-target`·`theme.syntax.keyword` 외 구문 색 열하나(`theme.syntax.<역할>`) | 그 화면이 모바일에 없다. 구문 색은 코드 편집기 전용이고 폰에는 그 편집기가 없다([native-editor-ui.md](native-editor-ui.md) §9.0) |
| `ssh.server-alive-interval`·`ssh.server-alive-count-max`·`ssh.reconnect` | **`maru ssh` 래퍼 전용이다.** 그 키들은 시스템 `ssh` 바이너리에 `-o` 로 넘어가고 끊기면 셸이 다시 부르는데, 모바일에는 `ssh` 바이너리도 그 셸도 없다 — 우리가 프로토콜을 직접 말한다([SSH 클라이언트](ssh-client.md)). 모바일의 끊김 감지·재접속은 **같은 이름의 키로 흉내 내지 않는다**: 내장 클라이언트에는 keepalive 를 거는 자리가 따로 있고(계약 §4.1), 재접속 여부는 host 가 소켓 수명과 함께 정한다. 필요해지면 그때 모바일 축의 키를 새로 연다 |
| `notifications.update-check` | 스토어가 한다 |
| `bell.dock-badge` | dock 이 없다. 앱 배지는 OS 알림 권한이 딸린 **다른 축**이라 이 키로 흉내 내지 않는다 |
| `cursor.unfocused` | 창이 하나라 "포커스 잃은 창" 이 없다 |
| `font.ligatures` | 글자를 **칸 단위로** 굽고 그린다. 합자는 셰이핑이 필요한데 그 경로가 없고, 있어도 격자와 어긋난다 |
| `scroll.multiplier` | 마우스 휠 축이다. 터치 스크롤의 느낌은 관성이 정하고 그건 host 몫이다([플랫폼 §3.1](mobile-platform.md)) |
| `chrome.theme` | 색 축은 `theme` 계열 하나로 둔다. 두 이름이 같은 것을 정하면 어느 쪽이 이기는지 사용자가 모른다 |

### 4.5 기본값이 데스크톱과 다른 것

**같은 키라도 기기가 다르면 기본값이 다르다.** 이것을 안 적으면 "왜 폰에서만 다르지" 가 된다.

| 키 | 데스크톱 | 모바일 | 왜 |
|---|---|---|---|
| `scrollback.lines` | 1000 | 더 작게 | 기기 메모리가 다르다. 셀 하나가 몇 바이트인지는 같아도 여유가 다르다 |
| `render.frame-rate` | 화면 주사율 | 30 | 전력이 예산이다([플랫폼 §3.2](mobile-platform.md)) |

## 5. 왜 못 여는지 — 이유가 긴 셋

- **`font.size` 를 여는 것은 글리프 기하와 한 몸이다.** 굽는 크기(`MARU_ATLAS_TEXT_PX`)와 그리는
  크기가 지금 따로 논다. 크기를 config 로 열면 그 어긋남이 곧 사용자에게 드러나므로, 이 키는
  **굽는 크기까지 함께 움직이는 슬라이스**에서만 연다.
- **`render.frame-rate` 의 상한은 config 가 못 올린다.** iOS 는 `CADisableMinimumFrameDuration`
  이 **번들에 박히는 능력 선언**이라 없으면 ProMotion 기기에서 조용히 60 으로 잘린다
  ([플랫폼 §3.2](mobile-platform.md)). 값을 여는 슬라이스는 그 키가 제품 번들에 있는지부터 본다.
- **원격 접속 프로필은 절반이 확정됐다.** **SSH 쪽은 열렸다**(사용자 확정 2026-08-17,
  [SSH 계약](ssh-client.md) §3.4) — 모바일엔 파일 편집기가 없어 UI 가 유일한 입력 경로이므로
  서버 목록을 앱이 들고 config 에 쓴다. 키 이름은 위 §4.3 이다. **컨트롤 플레인 접속(M3a)은
  여전히 이 계약 밖**이다 — 전송·인증이 정해져야 형태가 나온다([계획](plans/mobile-platform.md)).
  **자격증명은 어느 쪽이든 이 파일에 안 쓴다** — Keychain·Keystore 가 그 자리다.

## 6. 설정 화면은 스키마에서 나온다

**지금 화면의 줄과 스키마의 키가 안 맞는다.** 화면에는 필드가 쉰 개 넘게 있는데(PoC 가 라벨을
손으로 적었다) §4.1 이 여는 키는 열 개 남짓이다 — 나머지는 **뒤에 아무것도 없는 줄**이다.

그래서 화면을 스키마에 잇는 일은 "값을 배선한다" 가 아니라 **줄을 스키마에서 만든다** 이다.
**색 줄은 아직 안 낸다** — 16진 편집 수단이 없어 내면 눌러도 아무 일이 안 나는 줄이 되고,
그게 고치려던 문제 그 자체다. 편집 수단이 생기는 슬라이스에서 함께 낸다.

**고를 수 없으면 없는 값이다.** 화면이 유일한 입력 경로이므로(§2) 선택 목록을 자르거나 팝업이
화면 밖으로 넘치면 그 값은 **영영 못 쓴다** — 파일을 손으로 고칠 길이 없다. 실제로 프리셋을
enum 에서 만들자 16개가 되어 8칸 팝업에 절반이 잘렸고(`nord` 를 못 골랐다), 작은 폰에서는
목록 영역을 넘쳐 아래 항목이 화면 밖으로 나갔다. 그래서 **목록 상한은 가장 긴 목록에서
파생시키고**, 팝업은 목록 영역 안에 가두어 **밀 수 있게** 한다. 보이는 것만 누를 수 있다.

**숫자 칸은 OS 키보드를 쓰되 종류를 바꾼다.** 설정 화면에는 키보드가 이미 떠 있는데(앱이 안
내린다, [UX §5.2](mobile-ux.md)) 그 글자를 버리고 있었다 — 사용자에게는 **"키보드는 있는데
아무것도 안 써지는"** 상태였다. 숫자 줄을 누르면 그 줄이 입력 대상이 되고, host 가 키보드를
**숫자 패드로 갈아 끼운다**(iOS `UIKeyboardTypeNumberPad` + `reloadInputViews`, Android
`TYPE_CLASS_NUMBER` + `restartInput`). 종류만 바꾸고 다시 세우지 않으면 화면의 키보드는 그대로다.

- **자체 키패드를 그리지 않는다.** 그리면 화면에 키보드가 둘이 된다(OS 것은 안 내리므로).
- **터미널은 계속 글자다** — 거기서 ASCII 배열을 요구하면 한글이 불편해진다. 숫자 패드에는
  조합이 없어 그 위험이 숫자 칸에만 없다.
- **확정 전에는 config 를 안 건드린다.** 중간 값("5")이 적용되면 스크롤백이 5줄로 줄었다가
  돌아오는 것이 화면에 보인다. 확정은 Enter, 취소는 뒤로가기다.
- **범위는 스키마가 정한다**(`range` 메타). 화면이 숫자를 따로 적으면 파일 파싱과 GUI 가 다른
  값을 받아들인다. 범위 밖·숫자 아닌 글자·자릿수 초과는 **전부 신호를 남긴다**.

**안 되는 줄은 눌린 티도 내지 않는다.** 반응은 주고 아무 일도 안 하는 것이 "눌러도 안 되는 줄"
보다 나쁘다 — 사용자가 자기가 잘못 눌렀다고 여긴다.
손으로 적은 라벨은 지운다 — 남겨 두면 눌러도 아무 일이 안 나는 줄이 계속 남고, 그것은 지금
상태와 똑같다. 화면의 **형태**(행 44·팝업 앵커·섹션 헤더)는 [UX §5.6](mobile-ux.md)이 그대로
소유하고, 이 문서는 **무엇이 그 자리에 오는가**만 정한다.

## 7. 읽고 쓰는 경로

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
- **켤 때와 돌아올 때 읽는다.** 두 host 다 시작 시 한 번, 그리고 배경에서 돌아올 때 다시 읽는다
  — 파일을 고치고 돌아오면 그때부터 새 값이다. 한쪽만 다시 읽으면 같은 손짓의 결과가 플랫폼마다
  갈린다(Android 는 창이 부서졌다 서면서 이미 그렇게 하고 있었다).
- **크기 상한은 헤더가 소유한다**(`MARU_CONFIG_MAX_BYTES`, 데스크톱과 같은 1MB). host 마다
  숫자를 적으면 갈린다 — 실제로 갈려 있었다(Android 64KB·iOS 무제한·데스크톱 1MB).
  **넘치면 안 읽는다** — 자른 앞부분을 쓰면 "반만 적용된 설정" 이 되어 사용자가 무엇이 먹었는지
  알 수 없다. 두 host 다 `MARU_CONFIG too_large` 를 남기고 기본값으로 간다.
- **모르는 키는 무시하되 지우지 않는다.** 앱을 되돌려 깐 기기에서 새 키가 사라지면 안 된다.
- **쓰기가 실패하면 조용하지 않다** — 화면은 이미 바뀌었는데 다음에 켜면 돌아가 있으면
  사용자는 이유를 모른다.

## 8. 이 계약 밖

- **내보내기·가져오기** — 앱을 지우면 설정이 사라지는 것의 짝이다. 필요해지면 그때 정한다.
- **원격에서 설정을 밀어 넣기** — PC 의 config 를 안 끌어온다는 §1 과 정면으로 부딪히므로,
  하려면 그 결정을 먼저 뒤집어야 한다.
- **기기 간 동기화**(iCloud·Google 백업) — 자격증명 경계(§5)와 함께 정해야 한다.
