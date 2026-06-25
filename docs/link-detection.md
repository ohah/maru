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
  2. **공백 든 경로 1차 미지원**. maru 토큰은 항상 공백을 경계로 본다(한 토큰 = 공백 없는 run). 그래서
     Ghostty가 정규식 룩어헤드(`dotted_path_space_segments`)로 처리하는 `/tmp/a b/file.txt` 같은 공백 경로는
     `/tmp/a`까지만 잡는다. OSC 8 명시 링크나 후속 멀티-토큰 확장으로 우회한다(§한계).
  3. **클릭 시 파일 존재 검증(stat) 추가**. Ghostty 정규식엔 없는 단계로, 감지된 경로를 cwd/`$HOME`로 resolve해
     실제 존재할 때만 연다. bare-relative 경로의 오탐(영어 문장의 `a/b` 류)을 차단한다. iTerm2 Semantic
     History·VS Code 링크 프로바이더와 같은 방향.

## 감지 종류와 우선순위

토큰(공백 없는 run) 안에서 아래 우선순위로 **첫 매치**를 링크로 본다. 각 종류는 `LinkScopes` 비트로 독립
토글되며, 어떤 비트를 켤지는 `input.link-detection` config가 정한다(§config).

| # | 종류 | scope 비트 | 예 | kind |
|---|---|---|---|---|
| 1 | 스킴 URL (web) | `web` | `https://x`, `http://x`, `dot.http://x`(스킴부터) | url |
| 2 | 추가 스킴 | `extra_schemes` | `file://`, `mailto:`, `ssh://`, `ftp://`, `git://`, `tel:`, `news:`, `magnet:` | url |
| 3 | 절대 경로 | `absolute_path` | `/Users/me/a.zig`, `/etc/hosts` (`//`로 시작은 제외 — 주석·이중슬래시) | file_path |
| 4 | 홈 경로 | `home_path` | `~/.config/maru/config`, `~/notes.md` | file_path |
| 5 | 명시 상대 | `dot_relative` | `./src/main.zig`, `../lib/y.rb` | file_path |
| 6 | bare 상대 | `bare_relative` | `src/config/url.zig`, `app/x.rb:1` (슬래시 + 점 필수) | file_path |

- **스킴이 경로보다 우선**한다(`http://h:8080`은 URL의 포트지 줄번호가 아니다 — 스킴 가지가 먼저 잡아 안전).
- **bare-relative 오탐 억제**: 슬래시 필수 + 점 필수(콤마 전 head 기준) + `$`로 시작 금지 + `//` 금지.
  `foo/bar`(점 없음)·`input/output`·`$10/bar`는 매치하지 않는다. 남은 오탐은 stat 게이트가 거른다.
- **끝 다듬기**: 끝의 `,`(콤마는 다음 토큰 경계로 보고 잘라냄)·`. ; ) ] > ' "`(균형 안 맞는 닫는 괄호/따옴표)·
  매달린 `:`를 제거한다. `Foo_(bar)`처럼 균형 잡힌 괄호는 보존한다(URL과 동일 규칙).
- **`:line:col` 접미**: `file.zig:10:5`·`app/x.rb:1`의 `:<digits>(:<digits>)?`는 경로의 일부로 **보존**한다
  (에디터 줄 점프 관례). 단 1차 구현은 **여는 시점에 잘라 순수 경로만** 연다(`NSWorkspace.open`이 기본 앱으로
  파일을 열 뿐 — 에디터 줄 점프는 후속).

## resolve와 존재 검증 (클릭 경로)

감지된 raw 텍스트(kind=file_path)는 클릭 시 `core.zig`가 절대 경로로 resolve한다(파일 I/O는 코어 책임 —
순수 분류 레이어 `selection.zig`엔 stat을 두지 않는다):

```
:line:col 분리 → ~/ 를 $HOME 으로 확장 → 상대면 currentCwd()(OSC 7)와 join → 정규화(.. . 정리)
              → std.fs.accessAbsolute()로 존재 확인 → 있으면 절대 경로, 없으면 무시(null)
```

- **cwd가 비면**(OSC 7 미수신 셸·원격) 상대·bare 경로는 resolve 불가 → 안 연다. 절대 경로·`~/`는 cwd 없이 가능.
- **락**: `urlAt`은 `lockCore` 아래에서 분류·resolve·존재검증을 한다 — 분류가 스크롤백을, resolve가 cwd를
  읽는데 둘 다 reader 스레드가 OSC 7·출력으로 mutate하므로(cwd free+realloc, 스크롤백 evict) 락 없이 읽으면
  use-after-free·torn read가 난다(`focusedTermCwd`·`copyText`가 같은 위험을 락으로 고친 선례). 존재검증
  `access(F_OK)`는 빠른 syscall이라 락 아래 허용한다([io-render-threading](io-render-threading.md) §9.1).

## hover(밑줄)와 click(열림)의 의도적 불일치

- **hover**(`wordIsUrl`/`urlAnchorAt`)는 매 마우스 이동마다 불려 비용에 민감하므로 **stat을 하지 않는다** —
  패턴만 맞으면 밑줄·링크 커서를 띄운다.
- **click**(`extractUrlAt`)만 resolve+stat 게이트를 통과해야 실제로 연다.
- 결과: 존재하지 않는 경로에도 Cmd+hover 밑줄은 뜰 수 있으나 클릭하면 열리지 않는다. "밑줄=후보, 열림=검증"
  이라는 약한 불일치를 의도적으로 허용한다(hover에 디스크 I/O를 넣지 않기 위함). 더 엄격히 하려면 hover에도
  stat을 거는 후속이 가능하다.

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
  확인**한 경로만 `NSWorkspace.open`(기본 앱으로 열기)으로 연다. `std.fs.path.resolve`는 lexical 정규화라 `../`로
  cwd 밖을 가리킬 수 있으나, 결과는 "기본 앱으로 열기"지 **명령 실행이 아니다**(사용자가 직접 `open <path>` 하는
  것과 같은 권한, 권한 상승 없음). 절대 경로도 stat 게이트를 거치므로 Ghostty(절대 경로를 raw로 여는)보다 엄격하다.
- **스킴 URL·OSC 8 명시 링크**(`file://` 포함)는 존재 검증 없이 `URL(string:)`로 그대로 연다 — 프로그램이 지정한
  것이거나 명확한 스킴이라 신뢰한다. 따라서 `file:///path/X.app` 같은 URI는 `NSWorkspace`의 표준 동작상 **앱이
  실행될 수 있다**(Finder·Ghostty·iTerm2와 동일 — maru가 더 위험하지 않다). 임의 위치의 `.app`이 디스크에 이미
  있어야 하고 사용자가 명시 클릭해야 하므로 실질 추가 공격면은 낮다. 파일 열기 = filesystem capability
  ([터미널 호환성/보안 정책](terminal-compatibility-policy.md)).

## 한계와 후속

- **공백 든 경로 미지원**(토큰 모델 — 위 결정 2). 멀티-토큰 흡수는 오탐·복잡도가 커 후속.
- **`:line:col` 에디터 점프 미지원**(1차는 파일만 연다). `${EDITOR} +line file`은 별도 기능으로 후속.
- **`$VAR/` 경로 확장 미지원**(Ghostty는 함). `~/`만 확장. 후속 결정.
- **hover stat 미적용**(위 불일치). 후속 옵션.
- **추가 스킴 일부 미지원**: Ghostty의 `ipfs://`·`ipns://`·`gemini://`·`gopher://`와 colon-form `file:`·`ssh:`는
  데스크톱 사용 빈도가 낮아 뺐다(현재 지원 8종은 §감지 종류 표). 스킴이 더 적은 건 보수적이라 동작상 안전.
- **스킴 대소문자 구분**: `HTTP://`처럼 대문자 스킴은 감지 안 한다(소문자만). RFC 3986은 case-insensitive지만
  셸·로그 출력이 사실상 소문자라 1차는 소문자만 본다. 후속 결정.
- **`:line:col`은 2단까지**: `a/b.c:12:34:56`(3단 이상)은 resolve가 2단만 떼어 미존재로 떨어질 수 있다(안 열림 —
  안전 방향 실패). editor 관례가 `file:line:col`(2단)이라 실용 영향은 낮다.

## 코드 위치

- 순수 분류: `src/terminal/selection.zig` — `linkSpanInWord`(구 `urlSpanInWord`), `LinkKind`/`LinkScopes`/`LinkSpan`.
- resolve+stat·facade: `src/terminal/core.zig` — `extractUrlAt`, `resolveClickedPath`, `currentCwd`(OSC 7).
- 플랫폼: `src/platform/macos/app_session.zig`(`urlAt`·scopes 빌드·kind), `app_host_abi.{zig,h}`(`url_at` out_kind),
  `MaruAppHost.swift`(`handleUrlClick` — kind로 `URL(fileURLWithPath:)` vs `URL(string:)` 분기). ABI 경계는
  [macOS 앱 호스트 경계](macos-app-host-boundary.md).
- config: `src/config/theme.zig`(`InputConfig.link_detection`), `docs/configuration.md` 키 표.
