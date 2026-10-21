# 언어 서버 후보 확대 계획

상태: LS1~LS4 완료(2026-10-16 사용자 결정 — 「언어 서버 후보 확대」, 실물 검증을 위해 brew 전역 설치 허용). 서버 표의 계약은
[툴링](../editor-surface-tooling.md) §8.2a 「서버 찾기」·「설치 안내」가 소유한다. 이 문서는 후보 실측·결정·조각·검증을 소유한다.

## 왜

진단의 출처가 언어 서버뿐이 됐다([시각 매핑](../native-editor-visual-mapping.md) §5.4 「출처 결정」, 2026-10-15). 그런데 서버 표에 후보가 있는
문법은 열하나(Zig·C·C++·Objective-C·TS·TSX·JS·Rust·Python·Go)뿐이다. 나머지 문법은 진단·호버·정의 이동·자동완성이 하나도 없다 — 번들 언어
확대로 색과 접힘은 섰지만 그 위의 언어 기능은 비어 있다.

## 실측 — 후보 서버 (2026-10-16)

maru 주 서버 클라이언트와 **같은 능력**으로 말을 걸었다(임시 도구 — push 진단만 알리고, 서버가 묻는 요청은 전부 `-32601` 로 거절). 언어마다
깨진 원문을 열어 진단이 오는지, 고친 뒤 비워지는지 쟀다. 기계: macOS(arm64), 서버는 brew·npm·`dotnet tool` 로 설치했다.

| 문법 | 서버 | 인자 | languageId | 설치 | 실측 |
| --- | --- | --- | --- | --- | --- |
| Swift | `sourcekit-lsp` | — | `swift` | Xcode(또는 Command Line Tools — `/usr/bin` 에 있다) | 통과 — 기동 1.4 s, 진단 1.9 s(SwiftPM 없는 맨 파일도 1.1 s) |
| Dart | `dart` | `language-server --protocol=lsp` | `dart` | `brew install dart-sdk` | 통과 — 진단 0.4 s |
| C# | `csharp-ls` | — | `csharp` | `dotnet tool install --global csharp-ls` | 통과 — 진단 2 s. **`DOTNET_ROOT` 가 필요하다**(brew 의 .NET 은 caveat 대로 셸에 둬야 한다 — 없으면 기동 실패) |
| Scala | `metals` | — | `scala` | `brew install metals` | 통과 — 첫 기동은 빌드 도구를 내려받아 진단까지 79 s, 그 뒤 3.5 s. **저장(`didSave`)에 컴파일한다** — 고친 뒤 비우기도 저장에 |
| Java | `jdtls` | — | `java` | `brew install jdtls` | 통과 — 기동 4 s, 진단 1.7 s |
| Kotlin | `kotlin-language-server` | — | `kotlin` | `brew install kotlin-language-server` | 통과 — 진단 0.5 s |
| PHP | `intelephense` | `--stdio` | `php` | `npm i -g intelephense` | 통과 |
| Lua | `lua-language-server` | — | `lua` | `brew install lua-language-server` | 통과 |
| Bash | `bash-language-server` | `start` | `shellscript` | `npm i -g bash-language-server` | 통과 — **진단은 shellcheck 가 있을 때만**(`brew install shellcheck`), 없으면 호버·완성만 |
| YAML | `yaml-language-server` | `--stdio` | `yaml` | `npm i -g yaml-language-server` | 통과(설정 요청을 거절해도 기본 검사가 돈다) |
| TOML | `taplo` | `lsp stdio` | `toml` | `brew install taplo` | 통과 |
| Dockerfile | `docker-langserver` | `--stdio` | `dockerfile` | `npm i -g dockerfile-language-server-nodejs` | 통과 |
| JSON | `vscode-json-language-server` | `--stdio` | `json` | `npm i -g vscode-langservers-extracted` | 통과(push 로도 낸다) |
| CSS | `vscode-css-language-server` | `--stdio` | `css` | 같은 꾸러미 | 통과 |
| HTML | `vscode-html-language-server` | `--stdio` | `html` | 같은 꾸러미 | 통과(`<style>` 안 CSS 오류까지) |
| Ruby | `ruby-lsp` | — | `ruby` | `brew install ruby-lsp` | **pull 진단만 낸다** — push 만 알리는 주 서버 클라이언트로는 진단이 안 온다. pull 을 알리면 첫 진단은 서지만 **고쳐도 안 비워진다**: maru 의 전문 `didChange`(range 없음)를 `NoMethodError` 로 거부해 서버 사본이 연 때의 본문에 멈춘다(아래 「didChange 실측」) — LS3 이 range 꼴로 고쳐 LS4 에 싣는다 |

**실물에서 드러난 두 가지**(같은 도구로 maru 가 보낼 값을 그대로 보냈다):
- **SCSS·LESS 의 languageId** — 문법 `.css` 는 `.scss`·`.less` 도 덮는다. CSS 서버에 `css` 로 열면 `$c: red;`·`@c: red;` 에 거짓 오류가 **셋씩**,
  `scss`·`less` 로 열면 0 이다(같은 서버가 셋을 다 안다). 문서마다 그 방언의 값을 보낸다(`servers.languageIdForPath`).
- **Bash 서버와 zsh** — 문법 Bash 는 `.zsh` 도 덮는다. zsh 셰뱅(`#!/bin/zsh`)의 파일을 열면 shellcheck 가 「ShellCheck only supports sh/bash/dash/ksh」
  오류를 첫 줄에 낸다. Bash 서버는 `.zsh` 를 다루지 않는다(`Server.skip_extensions`) — 그 문서엔 주 서버가 없다. 색·접힘은 Bash 문법 그대로다.
  **남는 한계**: 확장자가 `.sh` 인데 셰뱅이 zsh 인 파일은 여전히 그 오류가 선다(확장자로 가르고 내용은 보지 않는다). `.zshrc` 같은 확장자 없는
  셸 파일은 문법이 `.none` 이라 서버가 아예 없다.

**싣지 않는 것**(실측 근거):
- SQL — `sql-language-server` 는 Node 24 에서 기동 실패(`ERR_PACKAGE_PATH_NOT_EXPORTED`), `sqls` 는 DB 연결이 없으면 진단을 안 낸다.
- Markdown — `marksman` 이 작업 폴더를 거부하고 진단(깨진 링크)도 안 냈다.
- XML·DTD — `lemminx` 는 brew 공식이 없고(GitHub 릴리스 바이너리, 서명 없음) 설정을 주지 않으면 진단을 안 냈다.
- Make — 쓸 만한 서버가 없다.

## 실측 — 주 서버의 pull·didChange 모양 (2026-10-21)

LS2 를 Ruby 로 실물 검증하다 드러난 것을 따로 쟀다(도구: 같은 편집 8단계 — 한글·이모지 줄, 개행 없는 끝, CRLF, 빈 파일 — 를 보내고 서버 사본이
maru 본문과 같은지를 진단 개수로 잰다. 방식 넷: range 없는 전문(지금) · range 로 문서 전체를 덮는 전문(utf-8·utf-16 제안 / utf-16 만) · 끝 위치를 일부러
코드포인트로 잘못 센 변이).

- **tsgo 는 파일 진단을 pull 로만 낸다.** push 는 tsconfig 의 진단뿐이다(7.0.0-dev 2026-01·03·04·07 판 전부; typescript-go 소스 `publishProjectDiagnostics`
  로 확인). 주 서버엔 pull 을 알리지 않았으므로 **tsgo 사용자에게 TS 오류가 하나도 서지 않았다** — 가짜 서버가 push 를 내서 판정자가 못 봤다.
  `diagnosticProvider.interFileDependencies` 는 참이다 — a.ts 만 고치고 b.ts 를 다시 물으면 b 의 오류가 바뀐다(실측). 디스크의 파일이 바뀌면(없던 모듈이 생김)
  `workspace/diagnostic/refresh` 를 보내되 **`workspace.diagnostics.refreshSupport` 를 알린 클라이언트에만** 보낸다(실측·소스). typescript-language-server(TS 5)·
  sourcekit-lsp 는 pull 을 안 알리면 push 로 낸다.
- **range 로 문서 전체를 덮는 전문은 열일곱 서버 모두에서 지금 모양과 단계마다 같은 결과다**(clangd·rust-analyzer·tsgo·typescript-language-server·pyright·
  gopls·zls·lua·yaml·css·docker·intelephense·dart·sourcekit-lsp·taplo·bash) — ruby-lsp 만 다르다: range 없는 전문을 `NoMethodError` 로 거부하고, range 를
  붙이면 통과한다. 끝 위치를 잘못 세면 거의 모든 서버가 조용히 어긋났고 rust-analyzer 는 죽었다. 전문만 받는다고 알린 서버(`change: 1` — taplo·bash)도
  bash 는 range 를 **적용한다** — 「전문 서버는 range 를 무시한다」에 기대지 않는다.
- **ruby-lsp 는 didChange 바로 뒤의 pull 에 한 박자 늦은 진단을 낸다.** 읽기 스레드는 요청이 오면 곧 파싱하고 didChange 는 큐에서 나중에 적용해, 둘이 한
  읽기에 오면 옛 본문의 진단을 계산해 캐시한다(다음 편집까지 그대로). maru 는 didChange 를 보낸 그 자리에서 pull 을 보낸다. 서버가 한가하면 5 ms 만
  띄워도 사라졌지만 **시간으로는 못 막는다** — 30 ms 를 띄워도 한 글자씩 칠 때 났다(LS4 실측: 타이핑마다 오는 완성 요청이 작업 스레드를 붙잡는다;
  RuboCop 진단은 더 길다). 소스로 본 원인: 읽기 스레드는 요청을 **그때 적용돼 있는 본문**으로 곧 파싱하고, 작업 스레드는 받은 순서대로 didChange 를
  적용만 하고(다시 파싱하지 않는다) 진단을 그 파싱 결과로 계산한다. 작업 스레드가 받은 순서대로라는 것이 해법이다 — didChange 뒤에 보낸 요청의 답이
  왔으면 그 didChange 는 적용됐다.
  ruby-lsp 는 줄바꿈으로 `\n` 만 센다(명세는 단독 `\r` 도 — 소스로 확인).
- **줄 모델이 서버마다 갈린다**(LS3 에서 잼 — 단독 `\r`·U+2028·U+2029 를 든 편집 열을 세 모델로 센 끝으로 보냈다): **clangd·gopls 는 `\n` 경계만**
  (maru 와 같다 — 명세 모델로 세면 찌꺼기가 남는다), **tsgo·pyright 는 명세대로 단독 `\r` 도 줄바꿈**(maru 모델로 세면 찌꺼기), zls·
  typescript-language-server 는 어느 모델이든 통과한다(넘친 끝을 줄 끝·문서 끝으로 묶는다). U+2028·U+2029 를 줄바꿈으로 세면 gopls 가 어긋난다(명세의
  줄바꿈도 아니다). range 없는 전문은 이 편집 열을 모든 서버가 통과한다.

## 결정

- 위 표의 통과한 열다섯(Swift·Dart·C#·Scala·Java·Kotlin·PHP·Lua·Bash·YAML·TOML·Dockerfile·JSON·CSS·HTML)을 서버 표에 싣는다. 후보는 각각 하나다.
- **주 서버에도 서버별로 pull 진단을 알리는 칸**을 둔다(보조 서버가 이미 쓰는 능력 — `InitOptions.pull_diagnostics`) — 켜는 것은 실측으로 push 를
  안 낸 tsgo·TS 7 의 `tsc`(LS2). 다른 서버의 동작은 바뀌지 않는다(그 칸이 꺼진 서버에는 지금처럼 알리지 않는다).
  - **칸은 서버 표 하나다**(LS2): `Server.pull_diagnostics`. 전엔 보조 서버 표(`Auxiliary.pull_diagnostics`)와 클라이언트(`Client.pull_diagnostics`)에 따로
    있었다 — 보조 서버도 `Server` 를 들므로 그 칸으로 옮겨, 주 서버·보조 서버가 같은 칸을 읽는다(두 벌이면 한쪽이 낡는다).
  - 주 서버의 pull 결과는 주 서버 칸(`lsp`)에 선다 — 응답이 칸을 고르는 자리(`serverDiagnostics`)가 이미 역할로 가른다.
  - 서버가 `interFileDependencies` 를 알렸으면 문서를 보낼 때마다 그 클라이언트의 다른 열린 문서도 다시 묻는다(LS2) — 한 파일의 타입이 다른
    파일의 오류를 바꾼다. 문서를 보내는 두 자리(처음 붙이기·동기화)가 한 함수(`pullAfterSend`)를 부른다.
  - pull 서버의 `initialize` 엔 `workspace.diagnostics.refreshSupport` 도 알린다(LS2) — refresh 처리(`null` 로 답하고 그 서버의 문서를 다시 묻는다)는
    이미 있었고, 알리지 않아 tsgo 가 보내지 않았다.
- **Ruby 는 LS4 에 싣는다** — 위 실측의 두 결함(range 없는 전문 거부·didChange 직후 pull 의 낡은 진단)을 LS3·LS4 가 먼저 고쳤다.
  - **LS3**: `didChange` 를 range 로 문서 전체를 덮는 전문으로 보낸다(명세의 증분 꼴에 전문을 싣는다 — 보내는 양은 그대로). 끝은 **직전에 보낸
    본문**의 마지막 줄 번호와 그 줄의 길이 — 줄은 maru 의 줄 모델(`LineIndex` — `\n`·`\r\n`; 진단·hover 의 위치와 같은 셈), 길이는 협상한 단위
    (`position.wholeRangeEnd`). 문서를 보내는 세 자리(처음 붙이기의 didOpen·재시작 뒤의 didOpen·didChange)가 `OpenDoc.markSent` 하나로 version 과 끝을
    함께 적는다. **직전 본문에 단독 `\r` 이 있으면 range 없는 전문**이다 — 위 실측대로 끝을 하나로 셀 수 없고, range 없는 전문은 그 본문을 모든
    서버가 통과한다(ruby-lsp 만 그때 거부한다 — 단독 `\r` 파일은 드물다). 서버가 알린 `change` 종류와 무관하다(`change: 1` 인 bash 도 range 를
    적용한다). 툴링 §8.2a 「동기화」 계약이 바뀐다. 2단 증분 동기화(바뀐 조각만)의 위치 셈을 먼저 갖춘다.
  - **LS4**: ruby-lsp 의 pull 앞에 **장벽**을 친다 — 서버 표의 칸 `pull_barrier`(ruby-lsp 만)가 켜진 서버엔 pull 대신 장벽 요청(위치 없는
    `textDocument/selectionRange` — 표준 요청, 답은 빈 배열; pull 과 같은 id 칸·같은 seq 열이라 i32 칸을 나누지 않는다)을 먼저 보내고 그 답(오류여도)이
    온 뒤에 묻는다. 기다리는 사이 다시 보내면 답이 와도 묻지 않고 장벽을 다시 친다. 시간을 띄우는 길(처음 판 — 30 ms 뒤 tick 에 묻기)은 실 ruby-lsp 로
    재니 타이핑 중 깨져 버렸다(위 실측). 다른 pull 서버(tsgo·`tsc`·ESLint)는 didChange 를 먼저 적용해 LS2 그대로 곧바로 묻는다. 가짜 서버가 ruby-lsp 의
    작업 스레드 지연을 본떠(pull 은 「pull 이 아닌 마지막 요청을 처리한 때」의 version 으로 답하고 다음 didChange 까지 캐시) 장벽 없이 물으면 판정자가
    옛 version 을 받는다. + Ruby 를 서버 표에(설치 `brew install ruby-lsp` — 자기 Ruby 를 든 공식;
    ruby-lsp 문서의 권장은 프로젝트 Ruby 의 `gem install ruby-lsp` 이고 그 길로 깐 것도 PATH 에 있으면 찾는다), 서버가 읽는 저장소 설정 표(WT5b-3)에
    `Gemfile`·`Gemfile.lock`·`.index.yml`(루트)·`.rubocop.yml`(가장 가까운 것) — ruby-lsp 는 첫 기동에 `Gemfile` 을 **평가하고** `bundle install` 을 돈다.
- 설치 안내는 표의 명령 그대로다(상태바 → 새 탭에 입력만). PATH 밖에 설치되는 것(`~/.dotnet/tools` 의 csharp-ls)·환경 변수가 필요한 것(`DOTNET_ROOT`)
  ·도구가 따로 필요한 것(shellcheck)은 툴링 문서의 설치 안내 절에 적는다 — 서버 찾기는 사용자 셸의 PATH 와 환경을 그대로 쓴다(§8.2a).
- JSON·CSS 는 보조 서버 Biome(§8.2u AS5)와 함께 간다 — 주 서버와 보조 서버는 칸이 따로라 서로의 진단을 지우지 않는다. 이로써 「주 서버 없이
  보조 서버만」인 문서가 없어져, AS5 가 그 경우를 위해 둔 갈래(정보 명령의 보조 서버 줄만·보조 서버 클라이언트로 신뢰 찾기·동기화의 보조
  서버만)를 **걷는다**(레거시를 남기지 않는다). 불변식 「보조 서버가 있는 문법엔 주 서버가 있고 그 확장자를 다룬다」는 판정자(`AUX6`)가 지킨다.
- 서버가 읽는 저장소 설정 파일 표(`config_files` — [워크스페이스 신뢰](workspace-trust.md) WT5b-3)에도 열다섯을 싣는다(각 서버의 공개 문서·
  소스로). YAML·Dockerfile·JSON·CSS·HTML 서버는 저장소 설정을 **읽지 않는다** — 표에 「읽지 않음」으로 올리고, 정보 명령은 「찾지 못함」 대신 그렇다고
  말한다(게이트의 `LSC1` 이 서버 표의 모든 서버가 그 표에 있는지 물어 드러났다).
- 문서를 보는 자리(붙이기·상태바·호버·정보·신뢰 관리)는 전부 **문서의 주 서버**(`serverForTerm` — 문법의 서버이되 그 확장자를 다루는 것)를 본다.
  한 자리라도 문법만 보면 「붙지 않는데 상태바엔 설치 안내」처럼 갈린다.

## 조각

| 조각 | 내용 | 상태 |
| --- | --- | --- |
| LS1 | 서버 표에 열다섯 — 실행 파일·인자·languageId·설치 명령, 판정자(이름표·languageId·설치 명령), 문서마다 languageId·다루지 않는 확장자, 툴링 문서의 서버 찾기·설치 안내 | 완료 |
| LS2 | 주 서버의 서버별 pull 진단(칸을 `Server` 하나로) + tsgo·TS 7 `tsc` 에 pull, 파일 간 의존이면 다른 열린 문서도 다시 묻기, pull 서버에 refresh 알림 | 완료 |
| LS3 | `didChange` 를 range 로 문서 전체를 덮는 전문으로(툴링 §8.2a 「동기화」 계약) — 직전에 보낸 본문의 끝 위치를 협상한 단위로, 단독 `\r` 뒤엔 range 없이 | 완료 |
| LS4 | pull 을 didChange 와 떼어 보내기 + Ruby(`ruby-lsp`) | 완료 |

## 검증

- 순수: 서버 표의 이름표·인자·languageId·설치 명령(`LSI1`·`LSI3`), pull 칸과 「켜진 자리는 일곱(TS·TSX·JS × tsgo·tsc, Ruby)」(`LSI8`), Ruby 행과 「장벽 칸이 켜진 자리는 그 하나」(`LSI9`), ruby-lsp 의 설정 파일(`LSC1`), 파일 간 의존 판정과 장벽 요청의 모양(`LSJ22`), 문서 전체를 덮는 range 의 끝(`LSP4` — 빈 문서·끝 개행·다바이트·CRLF·단독 CR)과 didChange 의 두 꼴(`LSJ2`), 문서마다 languageId 와 다루는 확장자(`LSI4`), 보조 서버 ⊂ 주 서버(`AUX6`).
- 제품 경로: `ASB7` — JSON·CSS 에 주 서버와 Biome 이 함께, `.scss`·`.less` 엔 주 서버만 그 방언의 languageId 로(가짜 서버가 받은 값을 진단에 싣는다 —
  `LANGID` 표식). `LSI5` — 같은 저장소의 `.sh` 엔 Bash 서버가 붙고 `.zsh` 엔 붙지도 상태바에 서지도 않으며 정보·신뢰 관리는 「언어 서버를 쓰는 편집기 문서에서 쓸 수 있습니다」. `LSI7` — tsgo 주 서버가 pull 로 진단을 세우고(그 클라이언트만 알린다 — pull 칸이 꺼진 C 서버는 알림을 못 받았음을 서버 쪽에서 잰다), 편집마다 다시 묻고, 한 문서를 고치거나 새 문서를 열면 다른 열린 문서도 다시 물어 파일 간 의존 진단이 그 문서에 서고 빠지며, 빈 목록이면 걷는다(가짜 서버를 `tsgo` 이름으로 — pull 만 낸다). `LSI6` — `.scss` 의 languageId 가
  didOpen 의 두 길(처음 붙일 때·서버가 죽어 다시 뜬 뒤 다시 열 때) 모두에서 `scss`. `LSD1`·`LSD2` — 편집 열(다바이트 끝·CRLF·끝 개행·큰 삭제·
  단독 CR 과 그 뒤·그 CR 지우기)의 단계마다 **서버 사본 = maru 본문**(가짜 서버가 받은 range 를 사본에 적용하고 사본 밖 위치는 거부한다 — `SYNCSUM`
  표식이 사본의 FNV-1a·range 없이 온 전문 수·거부 수를 싣는다), utf-8·utf-16 둘 다. `LSI10` — Ruby 주 서버(가짜 서버를 `ruby-lsp` 이름으로 — 작업 스레드 지연을 본뜬다)가 장벽 → pull 로
  진단을 세우고, 장벽의 답이 오기 전엔 묻지 않으며(답하지 않는 장벽 — `SSRSTALL`), 편집마다 그 본문의 진단이 서고(보낸 그 pump 에 장벽 하나, 그 뒤
  pull 하나), 기다리는 장벽이 있는 동안 다시 보내면 그 답에 묻지 않고 장벽을 다시 치고, refresh 도 장벽을 거치며, 장벽이 오류로 답해도 묻고, 빈
  목록이면 걷고, 장벽을 기다리는 채로 서버가 죽었다 다시 뜨면 다시 연 문서에 다시 친다.
- 실물: 위 실측 도구로 각 서버를 다시 돌려 표의 결과를 확인한다(PR 에 결과를 싣는다).
