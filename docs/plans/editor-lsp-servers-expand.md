# 언어 서버 후보 확대 계획

상태: LS1 완료, LS2 계획(2026-10-16 사용자 결정 — 「언어 서버 후보 확대」, 실물 검증을 위해 brew 전역 설치 허용). 서버 표의 계약은
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
| Ruby | `ruby-lsp` | — | `ruby` | `brew install ruby-lsp` | **pull 진단만 낸다** — push 만 알리는 지금의 주 서버 클라이언트로는 진단이 안 온다. pull 을 알리면 통과 |

**실물에서 드러난 두 가지**(같은 도구로 maru 가 보낼 값을 그대로 보냈다):
- **SCSS·LESS 의 languageId** — 문법 `.css` 는 `.scss`·`.less` 도 덮는다. CSS 서버에 `css` 로 열면 `$c: red;`·`@c: red;` 에 거짓 오류가 **셋씩**,
  `scss`·`less` 로 열면 0 이다(같은 서버가 셋을 다 안다). 문서마다 그 방언의 값을 보낸다(`servers.languageIdForPath`).
- **Bash 서버와 zsh** — 문법 Bash 는 `.zsh` 도 덮는다. zsh 셰뱅(`#!/bin/zsh`)의 파일을 열면 shellcheck 가 「ShellCheck only supports sh/bash/dash/ksh」
  오류를 첫 줄에 낸다. Bash 서버는 `.zsh` 를 다루지 않는다(`Server.skip_extensions`) — 그 문서엔 주 서버가 없다. 색·접힘은 Bash 문법 그대로다.

**싣지 않는 것**(실측 근거):
- SQL — `sql-language-server` 는 Node 24 에서 기동 실패(`ERR_PACKAGE_PATH_NOT_EXPORTED`), `sqls` 는 DB 연결이 없으면 진단을 안 낸다.
- Markdown — `marksman` 이 작업 폴더를 거부하고 진단(깨진 링크)도 안 냈다.
- XML·DTD — `lemminx` 는 brew 공식이 없고(GitHub 릴리스 바이너리, 서명 없음) 설정을 주지 않으면 진단을 안 냈다.
- Make — 쓸 만한 서버가 없다.

## 결정

- 위 표의 통과한 열다섯(Swift·Dart·C#·Scala·Java·Kotlin·PHP·Lua·Bash·YAML·TOML·Dockerfile·JSON·CSS·HTML)을 서버 표에 싣는다. 후보는 각각 하나다.
- Ruby 는 **주 서버에도 서버별로 pull 진단을 알리는 칸**을 둔다(보조 서버가 이미 쓰는 능력 — `InitOptions.pull_diagnostics`). 다른 서버의 동작은
  바뀌지 않는다(그 칸이 꺼진 서버에는 지금처럼 알리지 않는다).
- 설치 안내는 표의 명령 그대로다(상태바 → 새 탭에 입력만). PATH 밖에 설치되는 것(`~/.dotnet/tools` 의 csharp-ls)·환경 변수가 필요한 것(`DOTNET_ROOT`)
  ·도구가 따로 필요한 것(shellcheck)은 툴링 문서의 설치 안내 절에 적는다 — 서버 찾기는 사용자 셸의 PATH 와 환경을 그대로 쓴다(§8.2a).
- JSON·CSS 는 보조 서버 Biome(§8.2u AS5)와 함께 간다 — 주 서버와 보조 서버는 칸이 따로라 서로의 진단을 지우지 않는다. 이로써 「주 서버 없이
  보조 서버만」인 문서가 없어져, AS5 가 그 경우를 위해 둔 갈래(정보 명령의 보조 서버 줄만·보조 서버 클라이언트로 신뢰 찾기·동기화의 보조
  서버만)를 **걷는다**(레거시를 남기지 않는다). 불변식 「보조 서버가 있는 문법엔 주 서버가 있고 그 확장자를 다룬다」는 판정자(`AUX6`)가 지킨다.
- 문서를 보는 자리(붙이기·상태바·호버·정보·신뢰 관리)는 전부 **문서의 주 서버**(`serverForTerm` — 문법의 서버이되 그 확장자를 다루는 것)를 본다.
  한 자리라도 문법만 보면 「붙지 않는데 상태바엔 설치 안내」처럼 갈린다.

## 조각

| 조각 | 내용 | 상태 |
| --- | --- | --- |
| LS1 | 서버 표에 열다섯 — 실행 파일·인자·languageId·설치 명령, 판정자(이름표·languageId·설치 명령), 문서마다 languageId·다루지 않는 확장자, 툴링 문서의 서버 찾기·설치 안내 | 완료 |
| LS2 | 주 서버의 서버별 pull 진단 + Ruby(`ruby-lsp`) | 계획 |

## 검증

- 순수: 서버 표의 이름표·인자·languageId·설치 명령(`LSI1`·`LSI3`), 문서마다 languageId 와 다루는 확장자(`LSI4`), 보조 서버 ⊂ 주 서버(`AUX6`).
- 제품 경로: `ASB7` — JSON·CSS 에 주 서버와 Biome 이 함께, `.scss`·`.less` 엔 주 서버만 그 방언의 languageId 로(가짜 서버가 받은 값을 진단에 싣는다 —
  `LANGID` 표식). `LSI5` — 같은 저장소의 `.sh` 엔 Bash 서버가 붙고 `.zsh` 엔 붙지도 상태바에 서지도 않으며 정보·신뢰 관리는 「쓰지 않는 문서」.
- 실물: 위 실측 도구로 각 서버를 다시 돌려 표의 결과를 확인한다(PR 에 결과를 싣는다).
