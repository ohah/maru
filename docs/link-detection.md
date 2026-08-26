# 링크 감지 전략 (URL·파일 경로 Cmd+클릭 열기)

터미널 화면의 텍스트에서 URL·파일 경로를 감지해, 수식키(기본 Cmd)+hover면 밑줄·링크 커서를 띄우고
+클릭이면 기본 앱/브라우저로 여는 기능의 단일 출처 문서다. 수식키 정책은 `input.url-click-modifier`
([configuration](configuration.md))가, OSC 8 명시적 하이퍼링크는 [터미널 코어](terminal-core-decomposition.md)의
`osc.zig`(`dispatchHyperlink`)가 소유하고, 이 문서는 **보이는 텍스트의 자동 감지(휴리스틱)**를 다룬다.

## 두 가지 감지 경로

1. **OSC 8 명시적 하이퍼링크** — 프로그램이 `ESC]8;;URI ST text ESC]8;; ST`로 직접 표시한다(`eza`,
   `ls --hyperlink`, 일부 컴파일러). 추측이 없어 항상 우선이며, 이 문서의 범위 밖이다(이미 동작).
2. **자동 감지(휴리스틱)** — 평범한 화면 텍스트(`git status`·컴파일러 에러·`ls` 출력)를 스스로 스캔해
   링크처럼 생긴 부분을 찾는다. 이 문서가 다루는 부분이다.

## 베이스와 결정 (clean-room)

- **베이스**: Ghostty `references/ghostty/src/config/url.zig`의 *동작*(무엇을 링크로 보는가)을 베이스로 삼았다.
  Ghostty는 3-branch — (1) 스킴 URL, (2) rooted·dot-relative 경로, (3) bare-relative 경로 — 를 잡고,
  끝의 문장부호·`:`·`.`를 제외하며 괄호 균형을 맞춘다.
- **maru가 다르게 한 점**(레퍼런스와 갈린 지점 — project-rules.md §"단일 표준 없음" 의무):
  1. **정규식 미사용**. Ghostty는 oniguruma 정규식 1개로 매칭하지만, maru는 [런타임 의존성 0 정책](project-rules.md#의존성)
     을 지켜 oniguruma를 도입하지 않는다. Ghostty 정규식의 코드 표현(패턴 문자열·룩어헤드)을 복사하지 않고
     ([clean-room](project-rules.md)), maru 기존의 **공백-경계 토큰(`selection.zig wordBoundsAt`) + 순수 Zig
     문자열 분류**(`linkSpanInWord`)로 재구현했다.
  2. **공백 든 경로는 정규식이 아니라 존재로 잡는다**. maru 토큰은 공백을 경계로 보므로
     `C:\Program Files\x.txt`가 `C:\Program`에서 잘린다. Ghostty는 정규식 룩어헤드
     (`dotted_path_space_segments`)로 **문법**으로 가르지만, maru는 **존재검증으로** 가른다 — 토큰에서
     시작해 공백 세그먼트를 하나씩 붙여 물어보고 **실재하는 가장 긴 것**을 취한다(§공백 든 경로).
     산문은 저절로 멈춘다(그런 경로가 없으므로). `bare_relative`를 열 때와 같은 규율이다.
  3. **클릭 시 파일 존재 검증(stat) 추가**. Ghostty 정규식엔 없는 단계로, 감지된 경로를 cwd/`$HOME`로 resolve해
     실제 존재할 때만 연다. bare-relative 경로의 오탐(영어 문장의 `a/b` 류)을 차단한다. iTerm2 Semantic
     History·VS Code 링크 프로바이더와 같은 방향.
  4. **매치된 링크 span 자체가 U+2026 말줄임표로 잘렸으면 자동 링크로 보지 않는다.** 터미널 폭이나 UI 말줄임
     때문에 화면 텍스트 자체가 `…`로 잘린 경우 원본 URL/경로는 복원할 수 없고, 잘린 문자열을 여는 편이 더
     위험하다. 단 판정은 **매치된 span `[start, end)` 안의 `…`만** 본다 — 스킴 앞(`…https://example.com/page`)이나
     콤마 다음(`src/a.zig,…`)의 말줄임표는 링크 본문과 무관하므로 뒤따르는 온전한 링크는 그대로 감지한다(토큰
     어딘가에 `…`가 있다는 이유만으로 거부하면 회귀). 원본 URI가 따로 있는 경우는 OSC 8 명시 링크가 항상
     우선하므로, 보이는 텍스트가 `https://…`처럼 말줄임되어도 저장된 URI를 그대로 연다.

## 감지 종류와 우선순위

토큰(공백 없는 run) 안에서 아래 우선순위로 **첫 매치**를 링크로 본다. 각 종류는 `LinkScopes` 비트로 독립
토글되며, 어떤 비트를 켤지는 `input.link-detection` config가 정한다(§config).

| # | 종류 | scope 비트 | 예 | kind |
|---|---|---|---|---|
| 1 | 스킴 URL (web) | `web` | `https://x`, `http://x`, `dot.http://x`(스킴부터) | url |
| 2 | 추가 스킴 | `extra_schemes` | `file://`, `mailto:`, `ssh://`, `ftp://`, `git://`, `tel:`, `news:`, `magnet:` | url |
| 3 | 절대 경로 | `absolute_path` | `/Users/me/a.zig`, `/etc/hosts` (`//`로 시작은 제외 — 주석·이중슬래시). **Windows 호스트에서만** 드라이브 절대 `C:\x`·`C:/x`도 (아래) | file_path |
| 4 | 홈 경로 | `home_path` | `~/.config/maru/config`, `~/notes.md`. **Windows 호스트에서만** `~\notes.md`도 (아래) | file_path |
| 5 | 명시 상대 | `dot_relative` | `./src/main.zig`, `../lib/y.rb`. **Windows 호스트에서만** `.\src\main.zig`·`..\lib\y.rb`도 (아래) | file_path |
| 6 | bare 상대 | `bare_relative` | `src/config/url.zig`, `app/x.rb:1` (구분자 + 점 필수). **Windows 호스트에서만** `src\main.zig`도 (아래) | file_path |

- **역슬래시 철자(Windows 호스트)**: 네 갈래 전부 받는다 — `.\x`·`..\x`·`~\x`·`src\main.zig`. 앞의 셋은
  접두가 명확해 감지 단계에서 규칙이 성립하고, **bare 상대는 감지로는 못 가른다** — 이스케이프 출력과 구조가
  같기 때문이다:

  ```text
  src\main.zig      → [src][main.zig]
  line1\nline2.log  → [line1][nline2.log]
  ```

  그래도 받는 이유는 **뒤에 존재 게이트가 있기 때문**이다(§hover와 click). `line1\nline2.log`라는 파일은
  실재하지 않으므로 밑줄이 뜨지 않는다 — 규칙이 가르지 못하는 것을 존재가 가른다. 실제 도구 출력 코퍼스
  369 토큰 측정에서 이 갈래로 **새로 밑줄이 뜬 것은 3개, 셋 다 진짜 경로, 오탐 0**이다.

  **접두 형태는 접두 갈래가 판정을 소유한다** — `.\`·`..\`·`~\`로 시작하면 bare가 재판정하지 않는다. 안
  그러면 접두 갈래가 이스케이프로 보고 거부한 `.\d+`가 bare로 흘러들어 분류를 통과한다. 우선순위표가 이미
  `dot_relative`를 `bare_relative`보다 구체적이라고 정해 둔 것과 같은 규율이다.

  규칙과 그 오탐 대가는 `path_shape.detectableRelativePrefixFor`·`looksLikeBareRelativeFor`의 doc이, 후보를
  어떻게 골랐는지는 [windows-platform.md](windows-platform.md) §5.2 ⒜의 실측표가 단일 출처다. POSIX 철자는
  **모든 호스트에서 예전 그대로**다(회귀 0).
- **스킴이 경로보다 우선**한다(`http://h:8080`은 URL의 포트지 줄번호가 아니다 — 스킴 가지가 먼저 잡아 안전).
- **bare-relative 오탐 억제**: 슬래시 필수 + 점 필수(콤마 전 head 기준) + `$`로 시작 금지 + `//` 금지.
  `foo/bar`(점 없음)·`input/output`·`$10/bar`는 매치하지 않는다. 남은 오탐은 stat 게이트가 거른다.
- **끝 다듬기**: 끝의 `,`(콤마는 다음 토큰 경계로 보고 잘라냄)·`. ; ) ] > ' "`(균형 안 맞는 닫는 괄호/따옴표)·
  매달린 `:`를 제거한다. `Foo_(bar)`처럼 균형 잡힌 괄호는 보존한다(URL과 동일 규칙).
- **말줄임표 차단(span 국소)**: 매치된 링크 span `[start, end)` 안에 U+2026(`…`)이 있으면 잘린 것으로 보고
  감지하지 않는다(`spanIsTruncated`). span **밖**의 `…` — 스킴 앞(`…https://x`)·콤마 다음(`src/a.zig,…`) — 은
  무시하므로 뒤따르는 온전한 링크는 정상 감지한다. 이건 휴리스틱에만 적용되며, OSC 8 명시 링크는 셀의 link id로
  저장 URI를 먼저 회수하므로 영향을 받지 않는다. hover 판정(`wordIsUrl`, 2048B 스택 버퍼)과 클릭 추출
  (`extractUrlAt`, 전체 토큰)이 같은 결과를 내도록, 버퍼를 넘긴 토큰 뒷부분의 `…`도 hover가 끝까지 살펴 거부한다
  (어긋나면 "밑줄은 떠도 클릭하면 안 열림").
- **절대 경로 판정은 OS를 인자로 받는다**(`path_shape.isDetectableAbsoluteFor(os, path)`; 호출자는 호스트 OS를
  넘긴다): POSIX 절대(`/x`)는 어디서나, 드라이브 절대(`C:\x`·`C:/x`)는 **Windows에서만** 감지한다. 밑줄 span은
  콘텐츠를 가진 쪽이 만든다(원격도 host가 `collectViewportLinks`로 모은다). 로컬 hover는 이제 존재검증까지
  하므로 macOS에서 `C:\x`는 감지돼도 밑줄이 뜨지 않고, stat을 하지 않는 원격 host span에서만 "열리지 않는
  밑줄"이 남는다.
  - **부분집합 불변식**: 감지한 것은 반드시 `std.fs.path.isAbsolute`도 절대로 인정해야 한다. 아니면
    `resolveClickedPath`가 그 토큰을 **cwd에 join**해 엉뚱한 파일을 연다. 그래서 드라이브 뒤에 **구분자를
    요구**하고(`a:b`·`C:relative`는 감지하지 않는다), UNC(`\\server\share`·`//server/share`)와 드라이브 없는
    `\foo\bar`도 배제한다. 이 관계는 테스트가 단언한다.
  - **드라이브 문자를 A–Z로 제한하지 않는다** — Win32가 제한하지 않으므로(`1:/x`·`::/x`도 절대다) 그렇게 하면
    가드가 OS 파서보다 좁아져 우회로가 생긴다.
  - 상대 경로 세 갈래(`~/`·`./`·bare)도 **Windows에서는 역슬래시 철자를 받는다**(위 항목). 접두 둘은 세그먼트
    규칙으로, bare는 존재 게이트로 오탐을 막는다([windows-platform.md](windows-platform.md) §5.2 ⒜).
  - 근거와 실측: [windows-platform.md](windows-platform.md) §5.1. 이 술어는 경로 **가드**가 쓰는
    `path_shape.isAbsolute`(OS 무관하게 넓게 거부)와 **일부러 다르다**.
- **`:line:col` 접미**: `file.zig:10:5`·`app/x.rb:1`의 `:<digits>(:<digits>)?`는 경로의 일부로 **보존**한다
  (에디터 줄 점프 관례). 단 1차 구현은 **여는 시점에 잘라 순수 경로만** 연다(`NSWorkspace.open`이 기본 앱으로
  파일을 열 뿐 — 에디터 줄 점프는 후속).

## resolve와 존재 검증 (클릭 경로)

감지된 raw 텍스트(kind=file_path)는 클릭 시 `core.zig`가 절대 경로로 resolve한다(파일 I/O는 코어 책임 —
순수 분류 레이어 `selection.zig`엔 stat을 두지 않는다):

```
:line:col 분리 → ~/ 를 $HOME 으로 확장 → 상대면 currentCwd()(OSC 7)와 join → 정규화(.. . 정리)
              → pathExists 로 존재 확인 → 있으면 절대 경로, 없으면 무시(null)

              pathExists: POSIX = std.c.access(F_OK) / Windows = GetFileAttributesW(UTF-16)
              (CRT `_access`는 바이트를 ANSI 코드페이지로 읽어 비-ASCII 경로를 놓친다 — 위 §hover와 click)
```

- **cwd가 비면**(OSC 7 미수신 셸·원격) 상대·bare 경로는 resolve 불가 → 안 연다. 절대 경로·`~/`는 cwd 없이 가능.
- **락**: 클릭(`urlAt`)과 hover(`hoverCursor`의 `urlAnchorAt`) 분류를 **둘 다** `lockCore` 아래에서 한다 —
  분류(`wordIsUrl`/`urlAnchorAt`/`extractUrlAt`)가 스크롤백을, file_path resolve가 cwd를 읽는데 둘 다 reader
  스레드가 OSC 7·출력으로 mutate하므로(cwd free+realloc, 스크롤백 evict) 락 없이 읽으면 use-after-free·torn
  read가 난다(`focusedTermCwd`·`copyText`가 같은 위험을 락으로 고친 선례). hover는 매 mouse-move라 클릭보다
  빈번해 노출이 더 크다. 존재검증 `access(F_OK)`는 빠른 syscall이라 락 아래 허용([io-render-threading](plans/io-render-threading.md) §9.1).

## hover(밑줄)와 click(열림)은 같은 답을 낸다 (로컬)

- **hover**(`TerminalCore.openableLinkAnchorAt`)는 분류(`urlAnchorAt`)로 anchor를 잡은 뒤, 그 토큰이
  `file_path`이면 **클릭과 같은 술어** — 추출(`extractUrlAt`) → `resolveClickedPath` → 존재검증 — 을 통과해야
  밑줄·링크 커서를 띄운다. URL은 검증 없이 그대로 통과한다.
- **click**(`urlAt`)은 같은 추출+resolve+stat을 다시 밟아 연다. 즉 두 경로가 같은 함수를 쓴다.
- 결과: 존재하지 않는 경로에는 **밑줄이 뜨지 않는다**. "밑줄은 뜨는데 클릭하면 아무 일도 없는" 상태가 사라졌다.

**예전에는 달랐다.** hover가 매 마우스 이동마다 불린다는 이유로 stat을 뺐고, 그래서 `/nonexistent/x`나 Windows
쪽 감지 오탐(`n:\t` 등)에 밑줄만 뜨는 약한 불일치를 의도적으로 허용했다. 그 전제였던 비용을 실측해 뒤집었다 —
hover 1회가 **실재 경로 114.7 µs·없는 경로 118.1 µs·URL 38.0 µs**로 120Hz 마우스 이동 간격(8333 µs)의 **1.4 %
이하**다. **링크가 아닌 단어에서는 2.0 µs로 변화가 없고**(분류가 먼저 null을 낸다) **수식키를 누른 동안에만**
돈다. 느린 경우(UNC 죽은 호스트 755 ms)는 `path_shape.isDetectableAbsoluteFor`가 `\\` 토큰을 감지에서 이미
떨어뜨려 stat까지 닿지 않는다. 숫자·꼬리 지연 상한·남은 미지수(매핑됐지만 끊긴 네트워크 드라이브)는
[windows-platform.md §5.1a](windows-platform.md)가 소유한다.

**존재검증은 OS마다 다른 API를 쓴다**(`TerminalCore.pathExists`) — POSIX는 `std.c.access(F_OK)`, Windows는
`GetFileAttributesW`(UTF-16)다. Windows CRT의 `_access`가 바이트 경로를 ANSI 코드페이지로 읽어 `한글`·`日本`·
`café`·이모지 이름이 든 경로를 전부 "없음"으로 냈기 때문이다(실측 표는 위 §5.1a). 이건 hover 이전부터 클릭에
있던 결함이고, 두 경로가 같은 술어를 쓰게 되면서 드러났다.

**불변식**: `src/terminal/core.zig`의 *"hover와 클릭이 같은 답을 낸다 — 존재검증까지"* 가 실재 경로와 없는
경로를 두 OS 형태로 넣고 두 답이 어긋나지 않는지 단언한다.

**원격은 아직 예전 그대로다.** host-backed 세션의 밑줄은 host가 스냅샷에 실어 보낸 span이고 그 계산은 stat을
하지 않는다(§원격 표). plain ssh 세션은 `linkScopesForTerm`이 네 경로 scope를 모두 꺼서 경로 밑줄 자체가
없으므로 불일치가 생길 자리가 없다.

## 공백 든 경로 — 문법이 아니라 존재로 가른다

`C:\Program Files\x.txt`·`/Users/John Smith/notes.md`처럼 **공백이 든 경로**를 잡는다. 토큰 모델은 공백을
경계로 보므로 예전에는 `C:\Program`에서 잘렸고, 잘린 것은 존재 게이트가 죽여 **전혀 안 잡혔다**(실측).

**규칙**(`TerminalCore.openableLinkAt`): 토큰에서 시작해 공백 세그먼트를 하나씩 붙여 물어보고 **실재하는
가장 긴 것**을 취한다. 산문은 저절로 멈춘다 — `/tmp/a and then` 같은 경로가 없기 때문이다.

- **토큰이 실재해도 한 칸 더 물어본다.** 화면이 `…/Documents Backup`인데 토큰 `…/Documents`가 실재한다고
  거기서 끊으면 **사용자가 보는 것과 다른 것**을 연다(적대적 검증에서 잡은 실제 결함).
- **연속 실패 2회면 멈춘다.** 1이면 안 된다 — 주 사례가 첫 물음(`C:\Program`)에서 실패하고 두 번째에서
  성공한다. 세그먼트 상한은 5다(`C:\Program Files\Common Files\x.dll`이 2개).
- **URL은 확장하지 않는다** — 공백은 URL의 종결자이지 일부가 아니다.
- **OSC 8 명시 링크도 확장하지 않는다** — 그 범위는 셀의 link id가 정한다(`linkBoundsAt`). 토큰 경계로
  덮어쓰면 `My File Name` 같은 링크의 밑줄이 첫 단어로 **줄어든다**(이것도 검증에서 잡았다).
- **soft-wrap을 넘는다.** Windows 경로는 길어 자주 접힌다.

**밑줄 범위는 hover가 정해 실어 둔다.** `urlSpanAtAbs`는 토큰 경계를 재계산하므로 확장된 범위를 복원할 수
없고, 매 프레임 stat을 할 수도 없다. 그래서 hover가 한 번 정한 끝(`hover_url_end`)을 저장하고 렌더는
`spanBetweenAbs`로 클립만 한다. 안 그러면 "밑줄 밖을 눌러야 열리는" 상태가 된다.

**비용**(실측, Windows 10.0.19045, hover 1회 / 120Hz 이동 간격 8333 µs 대비):

| | 이전 | 지금 |
|---|---|---|
| 링크 아님 — 대부분의 이동 | 2.2 µs | **2.2 µs** (0.03 %) |
| URL | 26.6 µs | **26.6 µs** (0.32 %) |
| 실재 경로(공백 없음) | 98.8 µs | **198.3 µs** (2.38 %) |
| 없는 경로 | 118 µs | **224.9 µs** (2.70 %) |

공백 없는 경로가 두 배가 된 것은 "한 칸 더 물어본다" 규칙이 헛 stat 2회를 무는 대가다. 수식키를 누른
동안에만 돌고 이동 간격의 2.4 %라 받아들였다. 줄이려면 확장 프로브가 매번 셀을 다시 모으는 것
(`extractFromBounds`)을 캐시하는 것이 첫 수단이다.

**과확장은 실측으로 0이었다** — `build.zig and then some words`·`build.zig <다른 경로>`·`cd /repo && zig
build test`·`/repo/src for details` 넷 다 경로만 잡는다.

## 어느 pane에서 찾는가 (포인터 아래 pane이 소유)

클릭(`urlAt`)과 hover(`hoverCursor`) 모두 **포인터 좌표 아래 pane**의 화면에서 링크를 찾는다(`paneTargetAt` —
휠 라우팅과 공유하는 단일 출처). 포커스(활성 pane)와 무관하며, 링크를 여는 클릭이 pane 포커스를 바꾸지도 않는다.

- **왜 활성 pane 고정이면 안 되는가**: `pxToCell`은 좌표를 grid 안으로 **clamp**한다. 활성 pane에 고정하면 다른
  pane을 눌러도 "영역 밖(null)"이 아니라 **활성 pane의 엉뚱한 셀**이 나와, 조용히 아무것도 안 열리거나 최악엔
  다른 화면의 링크를 연다. 활성 Term이 **browser web Term**이면 그 surface는 렌더/PTY 없는 빈 sentinel core라
  좌표와 무관하게 늘 빈 결과였다 — "브라우저 패널을 띄우면 터미널 링크가 먹통"의 루트커즈(사용자 제보).
- **밑줄도 그 pane에만**: hover 상태는 anchor와 함께 **surface_id**를 싣고, 렌더는 `hoverLinkSpanFor(surface)`가
  id가 일치하는 pane에만 span을 준다. 활성·비활성 pane 렌더 경로가 이 함수를 공유하므로 비활성 pane에도 밑줄이
  뜬다 — 안 그리면 "밑줄은 없는데 클릭하면 열리는" 불일치가 생긴다(로컬에서 두 경로는 §hover와 click대로
  같은 답을 내야 한다).
- **포커스와의 관계**: 링크가 아닌 일반 클릭은 그대로 `Model.paneAtPoint`로 그 pane에 포커스를 옮긴다(수식키+클릭은
  URL 열기가 먼저 소비하므로 포커스가 안 옮겨간다). 즉 "브라우저를 보다가 옆 터미널 링크를 Cmd+클릭" 흐름에서
  포커스는 브라우저에 남고 링크만 열린다.
- **소비한 클릭의 짝도 앱에 안 간다**(2026-08-20 사용자 보고). host는 링크 클릭의 `down`을 소비하는데(Swift
  `handleUrlClick`이 true면 `handleMouse`를 안 부른다) 그 짝인 `up`은 리포트 경로로 흘러, 트래킹 중인 TUI가
  **press 없이 release만** 받았다. Claude Code가 그 release를 클릭으로 읽고 **자기도 같은 URL을 `/usr/bin/open`
  으로 열어** 브라우저가 두 번 떴다(LaunchServices 로그에 `maru-macos-app` 한 건과 `open` 한 건이 1초 간격으로
  남는다 — 그 1초는 자식 프로세스가 뜨는 시간이다). OSC 8 링크는 TUI가 스스로 만든 것이라 자체 열기 대상에서
  빠져 멀쩡했고, 화면 텍스트에서 TUI가 찾아낸 생 URL만 겹쳤다.
  짝을 맞추는 자리는 **리포트 직전 한 곳**이다(`app_session.mouse`의 `mouse_report_press_buttons`) — `mouse()`에는
  `kind == 1`에서만 삼키는 게이트가 여럿이라(상태바·팔레트·모달) 게이트마다 짝을 맞추면 규칙이 그 수만큼 늘고,
  새 게이트가 생길 때마다 같은 결함이 되살아난다. 링크만 100% 재현된 것은 그것이 **터미널 pane 안**이라 up이
  리포트까지 닿기 때문이지 나머지가 안전해서가 아니다.

## 링크를 어디에 여는가 (`input.link-open-target`)

무엇을 열지(§감지 종류)와 **어디에 띄울지**는 별개다. 후자는 `input.link-open-target`이 정한다.

| 값 | 보이는 브라우저 패널이 있을 때 | 없을 때 |
|---|---|---|
| `auto`(기본) | 그 패널에서 연다 | 시스템 기본 브라우저 |
| `in-app` | 그 패널에서 연다(재사용) | **새 browser 탭을 열어** 그곳에 띄운다 |
| `system` | 시스템 기본 브라우저 | 시스템 기본 브라우저(이전 동작) |

- **대상은 http(s) 리터럴만**이다. 파일 경로(`kind=file_path`)와 `mailto:`·`ssh://` 같은 비-HTTP 스킴은 이 설정과
  무관하게 기존 경로(`NSWorkspace`, `.md`/`.html`은 파일 도크)로 간다. 허용 스킴 판정은 파일 패널 외부 링크와 **같은**
  `isExplicitHttpLink`를 공유한다(단일 출처) — 브라우저 패널에 `file:`·`javascript:`가 실릴 경로를 구조적으로 막는다.
  길이 상한도 그 모듈의 `max_http_link_bytes`(8 KiB)가 단일 출처다. **파일 경로 상한(PATH_MAX=1024)을 쓰면 안 된다** —
  OAuth 콜백·pre-signed URL처럼 1 KB를 넘는 URL이 조용히 거부돼 같은 링크가 길이에 따라 다른 곳에서 열린다.
- **"보이는" 브라우저만 재사용 대상**이다. 각 pane의 **활성 Term**만 보고, 활성 pane의 브라우저를 먼저 고른 뒤 같은 탭의
  다른 pane을 순회한다. 숨은 Term 탭의 브라우저에 띄우면 화면이 그대로라 "아무 일도 안 일어난 것"처럼 보인다.
  여럿이면 이 순서의 첫 번째를 쓴다(브라우저를 둘 이상 띄우는 경우가 드물어 별도 정책을 두지 않는다).
- **기본이 `auto`인 근거**: 브라우저 패널을 띄워 둔 사용자는 링크를 그 패널에서 보길 기대하지만(사용자 결정), 패널이
  없는데 탭이 새로 생기는 건 놀람이 크다. `auto`는 패널이 없으면 동작이 이전과 **동일**해 브라우저를 안 쓰는 사용자에게
  회귀가 0이다. "터미널 링크는 늘 인앱에서 본다"면 `in-app`으로 올린다.
- **파일 패널의 `file-panel.external-link-target`과는 다른 설정**이다. 그쪽은 Markdown/HTML 문서 **안의** 링크를
  따라가는 문맥이라 `in-app`이 항상 **새** browser Term을 만들고 재사용 개념이 없다. 터미널 링크는 문서 문맥이 아니라
  분리한다(두 경로의 **실행**은 아래 pending action 하나로 합쳐 둔다).
- **경계와 순서**: 정책 판정은 Zig가 단일 출처로 소유하고(`openTerminalWebLink`), Swift는 결과가 `1`이면 그대로 두고
  `0`이면 `NSWorkspace.open`을 부른다(ABI v147 `open_terminal_web_link`). 인앱으로 정해진 링크는 **즉시 반환이 아니라
  pending action**으로 실린다 — 새로 만든 browser Term의 WKWebView는 **다음 tick의 surface 전이 batch**에서 생기므로,
  클릭 시점에 surface_id를 넘겨도 Swift `webPanels`에는 아직 없어 load가 유실된다. Swift는 매 tick 전이 batch를 적용한
  **뒤** `take_external_link_action`으로 drain하므로 "생성 → navigate" 순서가 구조적으로 보장된다(기존 패널 재사용도
  같은 경로로 보내 분기를 하나로 유지한다 — 한 tick 지연은 최대 ~16ms). 대상 패널이 그 사이 닫혔거나 load가 거부되면
  시스템 브라우저로 폴백한다 — 사용자가 누른 링크를 조용히 삼키지 않는다.
- **연타 보호**: drain 전 두 번째 요청은 거부하고 시스템 브라우저로 보낸다. pending URL을 덮어쓰면 앞 링크를 잃거나
  (in-app에서) 탭만 늘고 목적지가 바뀐 상태가 된다.

## soft-wrap(강제개행)된 링크

터미널 폭보다 긴 링크는 여러 화면 행으로 soft-wrap된다. `wordBoundsAt`(휴리스틱)·`linkBoundsAt`(OSC 8)이
`absRowWrapped`로 wrap 경계를 넘어 run을 이어, 어느 행을 클릭/hover해도 전체 링크를 회수한다.

- **hard newline 구분**: 실제 개행(`\n`)으로 쪼개진 줄은 별개 논리 행이라 이어붙이지 않는다(soft-wrap만 잇는다).
- **wide glyph wrap padding**: wide glyph(한글·CJK·와이드 이모지)가 줄 끝 한 칸에 안 들어가 다음 행으로 밀릴 때
  직전 행 끝에 padding 빈칸이 남는다(`screen.zig` putCell). 이 빈칸은 진짜 공백 경계가 아니라 wrap 패딩이므로
  run 이음에서 건너뛰고(`wordBoundsAtImpl`·`linkBoundsAt`), 이은 텍스트에서도 제외한다(`extractUrlAt`·`wordIsUrl`).
  안 그러면 **한글 든 링크가 wrap될 때 클릭이 끊긴다**(사용자 보고 버그 — 순수 ASCII wrap은 정상이라 드러나지
  않았던 회귀). continuation 칸(wide glyph 둘째 칸) 클릭도 같은 run으로 회수된다.
- 밑줄 범위(`urlSpanAtAbs`)는 선택 하이라이트와 같은 `clipAbsSpanToViewport`로 뷰포트에 클립돼, 스크롤·resize
  후에도 화면 밖 OOB가 안 생긴다. **공백 든 경로만 예외**다 — 그 범위는 존재검증으로 정해지므로 매 프레임
  재계산할 수 없다(프레임마다 stat을 할 수는 없다). hover가 한 번 정한 끝을 실어 두고 렌더는 그것을 클립만
  한다(§공백 든 경로).

## config (`input.link-detection`)

| 값 | 켜는 scope | 용도 |
|---|---|---|
| `osc8-only` | (없음) | 자동 감지를 끄고 OSC 8 명시 링크만 — 가장 보수적 |
| `web` | `web` | http(s)만 (이전 maru 동작과 동일) |
| `full` (기본) | 전부 | 스킴 + 절대/홈/상대/bare 경로 |

- **기본값 `full`**: 이번 기능은 "파일 링크가 안 열린다"는 버그 수정이고, 사용자가 bare 경로까지 원했으며,
  존재 stat 게이트가 오탐을 막으므로 회귀 위험이 낮아 기본 활성으로 둔다(maru의 "신규 키 회귀 없음 opt-in"
  선례와 갈리는 지점 — 버그 수정 성격이라 의도적). 좁히려면 `web`·`osc8-only`로 내린다.
- 수식키(`input.url-click-modifier`)·존재 검증과 직교한다.

## 보안

- **휴리스틱 파일 경로**(절대/홈/상대/bare)는 명시 제스처(수식키+클릭)에서만, cwd/`$HOME` resolve 후 **존재를
  확인**한 경로만 연다. `.md`/`.html` regular file은 현재 창 파일 도크로, 그 외는 `NSWorkspace.open`(기본 앱)으로 보낸다. 도크 경로는 ABI에서 종류와 regular-file을 재검증하고, 지원 확장자 검증 실패를 외부 앱으로 우회하지 않는다. `std.fs.path.resolve`는 lexical 정규화라 `../`로
  cwd 밖을 가리킬 수 있으나, 결과는 "기본 앱으로 열기"지 **명령 실행이 아니다**(사용자가 직접 `open <path>` 하는
  것과 같은 권한, 권한 상승 없음). 절대 경로도 stat 게이트를 거치므로 Ghostty(절대 경로를 raw로 여는)보다 엄격하다.
- **스킴 URL·OSC 8 명시 링크**(`file://` 포함)는 존재 검증 없이 `URL(string:)`로 그대로 연다 — 프로그램이 지정한
  것이거나 명확한 스킴이라 신뢰한다. 따라서 `file:///path/X.app` 같은 URI는 `NSWorkspace`의 표준 동작상 **앱이
  실행될 수 있다**(Finder·Ghostty·iTerm2와 동일 — maru가 더 위험하지 않다). 임의 위치의 `.app`이 디스크에 이미
  있어야 하고 사용자가 명시 클릭해야 하므로 실질 추가 공격면은 낮다. 파일 열기 = filesystem capability
  ([터미널 호환성/보안 정책](terminal-compatibility-policy.md)).

## 한계와 후속

- **원격에서는 공백 든 경로가 안 잡힌다** — host의 span 계산은 stat을 하지 않는데(§원격 표) 공백 확장은
  존재검증이 있어야 한다. 로컬만 §공백 든 경로대로 동작한다.
- **`:line:col` 에디터 점프 미지원**(1차는 파일만 연다). `${EDITOR} +line file`은 별도 기능으로 후속.
- **`$VAR/` 경로 확장 미지원**(Ghostty는 함). `~/`만 확장. 후속 결정.
- **원격 hover는 아직 stat을 하지 않는다**(위 §hover와 click). host의 span 계산에 존재검증을 넣을지는 후속.
- **추가 스킴 일부 미지원**: Ghostty의 `ipfs://`·`ipns://`·`gemini://`·`gopher://`와 colon-form `file:`·`ssh:`는
  데스크톱 사용 빈도가 낮아 뺐다(현재 지원 8종은 §감지 종류 표). 스킴이 더 적은 건 보수적이라 동작상 안전.
- **스킴 대소문자 구분**: `HTTP://`처럼 대문자 스킴은 감지 안 한다(소문자만). RFC 3986은 case-insensitive지만
  셸·로그 출력이 사실상 소문자라 1차는 소문자만 본다. 후속 결정.
- **`:line:col`은 2단까지, `:digits`로 끝나는 파일명과 모호**: `a/b.c:12:34:56`(3단 이상)은 resolve가 2단만 떼어
  미존재로 떨어질 수 있다(안 열림). 또 `logs/a:42`처럼 `:digits`로 끝나는 **실제 파일명**(macOS는 `:`를 허용)은
  줄번호로 오인해 스트립되므로 그 파일을 못 연다. editor 관례(`file:line:col`)를 우선한 트레이드오프 — `:digits`
  파일명은 드물어 실용 영향은 낮다.

## 원격(host-backed) 세션

[영속 세션 호스트](persistent-session-host.md)에 붙은 Term(`surface.remote != null`)은 화면을 host가 소유한다. client의
로컬 `TerminalCore`는 **미사용 placeholder**라(§`src/session/surface.zig` `Surface.remote` 주석) 위 감지 함수들을 그 core에
그대로 걸면 항상 빈 화면을 읽어 **밑줄도 커서도 클릭도 전부 동작하지 않는다**. 그래서 원격 경로는 host가 해석한다 —
"client 렌더 / host 해석" 불변식(선택 복사 `copyText`·Find가 이미 따르는 규율)을 링크에도 그대로 적용한다.
어느 기능을 host/client 중 어디에 두는지의 일반 규칙은 [영속 세션 호스트](persistent-session-host.md#기능을-어느-쪽에-둘-것인가-배치-규칙)가 단일 출처다.

| 단계 | 로컬(in-process) | 원격(host-backed) |
|---|---|---|
| hover 밑줄·커서 | client core를 직접 분류(`urlAnchorAt`) | host가 계산한 span을 **화면 스냅샷에 동봉**(`link_spans` record)해 client가 조회만 |
| 클릭 열기 | client core에서 추출+resolve+stat(`extractUrlAt`) | `runtime.link_at` RPC — **host가** 추출+resolve+stat |

- **왜 hover는 RPC가 아니라 스냅샷 동봉인가**: hover는 매 mouse-move(60~120Hz)라 왕복을 넣으면 커서 지연이 그대로 보인다.
  화면이 바뀔 때만 갱신되는 span 목록을 실어 보내면 client 조회는 순수 로컬 검색이라 왕복이 0이다. `prompt_marks`(행별 OSC 133)가
  같은 이유로 쓰는 dense full-replace 패턴을 그대로 따른다.
- **왜 클릭은 RPC인가**: 열 대상 텍스트는 soft-wrap 이음·스크롤백 충실이 필요하고, `file_path`의 resolve(cwd)와 존재 검증(stat)은
  **콘텐츠와 cwd를 가진 host의 파일시스템**에서 해야 맞다. client가 자기 FS로 stat하면 원격 host의 경로를 잘못 판정한다.
  `runtime.selected_text`(선택 복사)와 같은 형태다.
- **scope 정책은 client가 정한다**: `input.link-detection`은 client config이고 host는 이를 모른다. host는 **최대 집합(`full`)으로
  계산**해 span마다 매치된 scope 비트를 함께 싣고, client가 자기 config로 거른다. host에 config를 미러링하는 대신 이 분리를 택한
  이유는 (1) config 변경 때마다 host 상태를 동기화할 필요가 없고, (2) 여러 client가 서로 다른 `link-detection`으로 같은 host에
  붙어도 각자의 정책이 적용되기 때문이다(§[다중 client](persistent-session-host.md#9-다중-client와-resize)).
- **hover/click 불일치가 원격에만 남았다**: host의 span 계산은 stat을 하지 않고(hover), `runtime.link_at`만 resolve+stat을 한다
  (click). 로컬은 §hover와 click에서 이 불일치를 닫았으므로 **원격만 예전 규칙**이고, 그래서 원격에서는 존재하지 않는
  경로에도 밑줄이 뜰 수 있다.
- **OSC 8 명시 링크도 같은 record로 간다**: screen-stream의 `run`에는 셀의 OSC 8 link id 필드가 **없다**(`grapheme|width|
  count|fg|bg|underline_color|style_flags`가 전부). 즉 원격에서는 자동 감지뿐 아니라 **명시 하이퍼링크도 client 셀에 도달하지
  않는다** — 이 문서 §두 가지 감지 경로가 "OSC 8은 항상 우선"이라고 한 전제가 host-backed에서는 성립하지 않았다. 그래서 host는
  `link_spans`에 자동 감지 span과 **OSC 8 span을 함께** 싣고(`scope=osc8` 비트), client는 osc8 비트를 `input.link-detection`
  프리셋과 무관하게 항상 표시한다(로컬에서 OSC 8이 scope 토글과 무관한 것과 동일). 열기 역시 `runtime.link_at`이 host의
  `extractUrlAt`을 부르므로 저장된 URI가 그대로 쓰인다.
- **capability와 구 host 호환**: `runtime_link_at_v1`을 광고하지 않는 구 host에는 클릭 RPC를 보내지 않고, `link_spans`를 보내지
  않는 구 host에서는 자동 감지·OSC 8 링크가 모두 비활성이다(현재 동작과 같음 — 새로 잃는 기능이 없다). 감지가 조용히 빈
  결과를 내는 것이 잘못된 경로를 여는 것보다 안전하다.
- **scope 필터의 근사 한계**: host는 `full` 기준 한 번만 계산하고 span마다 매치 scope를 태그한다. `input.link-detection`이
  프리셋 3종(`osc8-only`/`web`/`full`)뿐이라 실제 필터 결과는 로컬과 같지만, 한 토큰 안에 web 스킴과 추가 스킴이 함께 있고
  추가 스킴이 더 앞서는 극단적 입력에서는 `web` 프리셋의 매치가 로컬과 갈릴 수 있다. 프리셋별 재계산은 비용 대비 실익이 없어
  후속으로 둔다(임의 비트 조합 config가 생기면 재검토).

## 코드 위치

- 순수 분류: `src/terminal/selection.zig` — `linkSpanInWord`(구 `urlSpanInWord`), `LinkKind`/`LinkScopes`/`LinkSpan`,
  뷰포트 전체 수집 `collectViewportLinks`(원격 host가 방출할 span 목록을 만드는 단일 출처 — 로컬 조회와 같은 분류기를 쓴다).
- resolve+stat·facade: `src/terminal/core.zig` — `extractUrlAt`, `resolveClickedPath`, `currentCwd`(OSC 7).
- 원격(host-backed): wire record `src/session/screen_stream.zig`(`link_spans`), host 방출
  `screen_snapshot.zig`, client 조립 `screen_assembler.zig`·`remote_screen.zig`, 클릭 RPC `remote_runtime.zig`
  (`runtime.link_at`)·`server.zig`. 설계 근거는 위 §원격(host-backed) 세션.
- 플랫폼: `src/platform/macos/app_session.zig`(`urlAt`·`hoverCursor`·pane 라우팅 `paneTargetAt`·밑줄 `hoverLinkSpanFor`·
  scopes 빌드·kind·`openFilePanelPath`), `app_host_abi.{zig,h}`(`url_at` out_kind·파일 패널 ABI),
  `MaruAppHost.swift`(`handleUrlClick` — `.md`/`.html`은 도크, 그 외는 `URL(fileURLWithPath:)`/`URL(string:)`). ABI 경계는
  [macOS 앱 호스트 경계](macos-app-host-boundary.md).
- 열기 대상 라우팅: `src/platform/macos/app_session.zig`(`openTerminalWebLink` — 정책 단일 출처,
  `visibleBrowserSurfaceId`·`queueExternalLinkAction`[파일 패널과 공유하는 실행 경로]),
  `app_host_abi.{zig,h}`(`open_terminal_web_link`·`take_external_link_action`, ABI v147),
  `MaruAppHost.swift`(`handleUrlClick`가 0이면 `NSWorkspace.open` / tick drain이 `BrowserControl.navigate`).
  URL 허용 스킴·길이 상한은 `src/session/file_panel_bridge.zig`(`isExplicitHttpLink`·`max_http_link_bytes`).
  브라우저 패널 자체는 [웹 패널](web-panel.md).
- config: `src/config/theme.zig`(`InputConfig.link_detection`·`InputConfig.link_open_target`), `docs/configuration.md` 키 표.
