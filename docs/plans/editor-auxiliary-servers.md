# 보조 언어 서버 구현 계획

상태: AS1(구조·ruff 진단)·AS2(code action 을 서버 여럿에서)·AS3(ESLint) 완료, AS4(Biome·oxlint)·AS5(주 서버가 없는 문법 — Biome 의 JSON·CSS) 완료. 계약은 [tooling §8.2u](../editor-surface-tooling.md)가 소유하고, 이 문서는 결정·설계·조각·검증을 소유한다. 언어 서버의 공통 계약은 §8.2a 다.

## 왜

린트 진단과 린트 fix(ESLint·ruff)가 편집기에 없다. 지금 구조는 **한 문서에 언어 서버 하나**라(§8.2a 「서버 찾기」 — 후보 중 찾아지는 첫 것), TS 문서에 tsgo 와 ESLint 를,
Python 문서에 pyright 와 ruff 를 함께 붙이지 못한다. 저장 시 code action(§8.2s)의 `source.fixAll.eslint` 도, 외부 포매터 계획(EF)이 「보조 언어 서버로」 미룬 린트 fix 도 이것을 기다린다.

## 결정 (2026-10-13 사용자, 모두 권장안)

- **첫 범위는 ESLint + ruff.** TS·JS 에 ESLint 언어 서버(`vscode-eslint-language-server`), Python 에 `ruff server`. Biome(`biome lsp-proxy`)·oxlint 는 같은 틀에 다음 조각으로.
- **저장소 설정이 있을 때만 띄운다.** ESLint 설정(`eslint.config.*`·`.eslintrc*`)이 있으면 ESLint, ruff 설정(`ruff.toml`·`.ruff.toml`·`pyproject.toml` 의 `[tool.ruff…]`)이 있으면 ruff. 외부 포매터 감지(§8.2t)와 같은 방식 — 설정 없는 저장소에선 아무 일도 없다.
- **보조 서버는 진단과 code action 만 맡는다.** 밑줄·거터·F8·호버의 진단 줄, `⌘.` 메뉴, 저장 시 code action(`source.fixAll.eslint`·`source.fixAll.ruff`·`source.organizeImports.ruff`). 호버·완성·이름 바꾸기·정의 이동·포맷 등은 주 서버만 — 포맷은 외부 포매터가 이미 맡는다.
- **실행 파일은 저장소 먼저, 그다음 PATH.** 문서 폴더에서 루트까지 `node_modules/.bin`·`.venv/bin`·`venv/bin`(외부 포매터와 같은 함수 `findLocalBin`), 없으면 저장소 셸 환경의 PATH. 저장소 안 실행 파일임을 정보 명령·신뢰 시트가 보인다.

## 실측 (2026-10-13, 임시 폴더에 설치 — `vscode-langservers-extracted` 4.10.0 + ESLint 9.39, ruff 0.17.0)

| | ESLint 언어 서버 | `ruff server` |
| --- | --- | --- |
| 진단 | **pull 만**(`diagnosticProvider{identifier: eslint}`) — push 를 40 초 기다려도 오지 않는다. `textDocument/diagnostic` 을 물어야 검사한다(그 전엔 fixAll 도 빈 목록) | 클라이언트가 pull 을 알리지 않으면 **push**(`publishDiagnostics`) |
| 서버 → 클라이언트 요청 | `workspace/configuration`(`section: ""`) — **설정 객체로 답해야 돈다**(`null` 이면 진단 요청이 `Cannot read properties of null (reading 'workingDirectory')` 로 실패). `client/registerCapability`(작업 폴더 변경) | 없음(동적 등록이 없으면 경고 줄만) |
| code action kind | `quickfix`·`source.fixAll.eslint` | `quickfix`·`source.fixAll.ruff`·`source.organizeImports.ruff`(`resolveProvider`) |
| fixAll | `edit.documentChanges`(그 문서만) | `edit.changes`(그 문서만) |
| 줄 단위 quickfix | **`command` 만**(`eslint.applySingleFix`·`applyDisableLine`…) — 지금 규칙(§8.2h ⑤ command-only 거름)으론 메뉴에 안 뜬다 | `edit`(규칙별 fix·`# noqa` 넣기) |
| 그 밖 | `eslint/status` 알림, 실행 파일은 저장소의 `eslint` 라이브러리를 `node_modules` 에서 찾는다 | `hoverProvider`·`documentFormattingProvider` — 보조 서버라 쓰지 않는다 |

## 설계

### 서버 표와 감지 (순수 층)

- `session/lsp/auxiliary.zig` 가 **보조 서버 표**와 감지를 함께 든다: `forGrammar(Grammar) []const Auxiliary` — Python → ruff(AS1), JS·TS·TSX → ESLint(AS3). `Auxiliary{tool, server: Server, bin_dirs}`.
  주 서버 표(`servers.candidatesFor`)는 그대로다 — 보조는 「후보 중 하나」가 아니라 **주 서버와 함께** 뜬다.
- 감지(`detect`)는 문서 폴더에서 저장소 루트까지 올라가며 그 도구의 설정을 찾는다(외부 포매터의 `DirsUp`·`tomlHasTable` 을 쓴다 — 두 벌이면 한쪽만 낡는다).
  - ruff: `ruff.toml`·`.ruff.toml`, 또는 `pyproject.toml` 의 `[tool.ruff]`·`[tool.ruff.<무엇>]` 표 머리.
  - ESLint(AS3): `eslint.config.{js,mjs,cjs,ts,mts,cts}`, `.eslintrc`, `.eslintrc.{js,cjs,json,yaml,yml}`, `package.json` 의 최상위 `eslintConfig`.
- 감지 결과는 문서마다 한 번 굳힌다(열 때 — 설정 파일을 그 뒤에 만들면 문서를 다시 열어야 한다; 받아들일 한계).

### 클라이언트

- 클라이언트 표의 열쇠는 지금처럼 `(root, exe)` 다. `Client.role: primary | auxiliary` 를 더한다.
- 보조 클라이언트의 실행 파일은 그 클라이언트를 세운 문서의 폴더에서 `findLocalBinIn`(외부 포매터의 `findLocalBin` 몸을 폴더 목록·이름으로 가른 것)으로 찾은 **절대 경로**(있으면), 아니면 PATH 의 이름이다. 신뢰 시트·정보 명령의 출처 분류(`exe_origin`)가 저장소 안을 가른다.
- 신뢰는 저장소 단위 그대로다 — 같은 저장소의 서버 전부를 한 시트가 덮는다(§8.2a). 설정을 찾았는데 실행 파일이 없으면 「없음」으로 조용히 선다(상태바는 주 서버만 — 정보 명령이 보인다).
- 문서 동기화(`syncDocuments`)는 주 서버 다음에 그 문서의 보조 서버마다 같은 길(`ensureClient` → `gateTrust` → `syncOne`)을 탄다. 주 서버가 없어도(설치 안 됨) 보조 서버는 뜬다.
- **보조 클라이언트에 보내는 요청은 code action·code action resolve(AS2)·pull 진단(AS3)뿐**이다. 응답 입구(`handleFrame`)는 보조 클라이언트의 그 밖 응답을 버린다 — 요청 번호(seq)는 클라이언트마다 따로 세서, 보조 서버의 응답이 주 서버의 대기와 번호가 같을 수 있다. AS1 은 `initialize`·`shutdown` 만 받는다.
- 언어별 설정 블롭(§8.2n `didChangeConfigurationFor(language_id)`)은 주 서버에만 보낸다 — ESLint 의 `language_id` 가 `javascript` 라 그대로면 TS 의 힌트 설정이 간다.

### 진단

- 문서의 서버 진단을 **서버마다 따로** 든다(`editor_diagnostics` 의 서버 칸 여럿 — 열쇠는 그 클라이언트의 exe). `publishDiagnostics` 는 그 서버의 칸만 갈아 끼우고, 서버를 내릴 때도 그 칸만 걷는다(지금은 한 칸이라 두 번째 서버가 첫 서버의 것을 지운다).
- 합친 목록(`list`)은 서버 칸 전부 + 구문 오류를 정렬한 것이다(§5.4 — 지금 규칙 그대로).
- 진단마다 **어느 서버의 것인지**를 든다. 호버의 진단 줄(§8.3)은 지금 문법의 주 서버 이름을 붙이는데, 그러면 ruff 의 진단이 「pyright」로 보인다 — 진단이 든 서버 이름을 쓴다.
- code action 요청의 문맥 진단(`context.diagnostics`)은 **그 서버의 진단만** 싣는다 — 서버는 자기가 낸 진단의 `data` 로 fix 를 만든다.
- pull 진단(AS3): `diagnosticProvider` 가 있고 push 를 안 하는 서버(ESLint)에는 보조 클라이언트의 `initialize` 에 `textDocument.diagnostic` 능력을 알리고, 문서를 보낼 때마다(didOpen·didChange 뒤, 같은 묶음 규칙) `textDocument/diagnostic`(id 칸 `20e8` — `17e8`~`19e8` 은 그 사이 심볼·강조·선택 확장이 썼다; i32 안의 마지막 칸)을 묻는다. 응답의 `kind: full` 은 그 서버 칸을 갈아 끼우고 `unchanged` 는 그대로 둔다. 물은 뒤 문서가 바뀌었으면 버린다. 주 서버에는 알리지 않는다(tsgo 등이 push 에서 pull 로 바꾸면 지금 동작이 바뀐다).

### code action (AS2)

- `⌘.` 메뉴: 주 서버와 보조 서버 각각에 묻고(서버마다 자기 진단을 문맥으로), 응답을 **모두 받거나 시한**이 되면 합쳐 낸다(주 서버 먼저). 항목은 그 서버를 기억한다 — resolve 는 그 서버에 보낸다.
- 저장 시 code action: 설정 kind 마다 그 kind 를 지원하는(`codeActionKinds` 가 덮는 — `source.fixAll` 은 `source.fixAll.eslint` 를 덮는다) 서버에 차례로 묻는다(주 서버 먼저). 하나를 적용하면 revision 이 올라 다음 요청이 새 본문을 본다(§8.2s 그대로).
- ESLint 의 줄 단위 quickfix 는 `command` 만이라 메뉴에 안 뜬다(§8.2h ⑤ 그대로). `workspace/executeCommand`·`workspace/applyEdit` 는 이 계획 밖이다.

### AS2 설계 메모

- **진단 `data`·`source` 왕복**: ruff 는 진단마다 `data`(규칙별 fix 편집·`# noqa` 편집)를 싣고 `⌘.` 의 줄 단위 quickfix 를 그것으로 만든다(LSP 3.16
  「publish 와 codeAction 사이에 보존」). 그리고 **문맥 진단의 `source` 가 `Ruff` 일 때만** 낸다 — `data` 만 되돌리면 「Fix all」·「Organize imports」만
  오고 줄 단위 fix 가 없다(진짜 ruff 0.17.0 실측, 적대적 2회차). `Diagnostic.data`(JSON 원문)·`source_text` 를 메시지 저장소에 함께 들고
  (`appendDiagnostics` 가 먼저 크기를 재 저장소를 잡는다 — 슬라이스가 그 안을 가리킨다), `ContextDiagnostic` 이 그대로 되돌린다(`jsonStringify`).
- **kind 목록**: `CodeActionCaps` 에 서버가 알린 `codeActionKinds` 의 사본(256 바이트 — 넘치면 모르는 것으로 두고 묻는다). `covers` 는 위계 양쪽
  (`source.fixAll` ↔ `source.fixAll.ruff`). 목록이 없으면 무엇이든. **주 서버에도 적용된다** — 알린 kind 밖은 묻지 않는다(LSP: 「서버가 낼 수 있는
  kind」 — VS Code 도 `providedCodeActionKinds` 로 provider 를 거른다). 가짜 서버도 실서버처럼 제 kind 를 알리게 했다.
- **메뉴 시한**: 첫 답이 오기 전에는 시한이 없다(서버 하나일 때와 같다 — rust-analyzer 의 code action 은 1 초를 넘길 수 있다). 첫 답 뒤 0.5 초.
  모으는 목록(`pending`)과 열린 메뉴가 빌려 쓰는 목록(`items`)을 갈라, 다 모은 뒤 바꾼다.
- **서버는 이름으로 든다**: 클라이언트 표는 자라며 옮겨지므로 메뉴 항목·저장 단계는 포인터 대신 실행 파일 이름(서버 표의 정적 문자열)을 들고
  `docClientByExe` 로 되찾는다.

### 서버 → 클라이언트 요청 (AS3)

- §8.2a 는 서버 요청을 전부 거부한다. 예외를 하나 더한다: **`workspace/configuration` 에 서버 표의 고정 설정으로 답한다**(그 서버에 정해 둔 블롭이 있을 때만 — ESLint; 없으면 지금처럼 거부). 읽기 요청이고 답은 우리 상수라 승인 UI 가 필요한 「행동」이 아니다.
- `client/registerCapability` 는 지금처럼 거부한다(ESLint 는 작업 폴더 변경 알림만 등록하려 한다 — 거부돼도 진단·fix 는 돈다; 진짜 서버로 확인).
- `workspace/diagnostic/refresh`(설정·의존 파일이 바뀌면 pull 서버가 보낸다)는 `null` 로 받고 그 서버의 문서를 다시 묻는다.

### AS3 설계 메모

- **ESLint 의 설정**: vscode-eslint 확장이 보내는 모양을 따른다. 진짜 서버(4.10)로 잰 필수: `workingDirectory` 객체(없으면 `reading 'workingDirectory'`), `experimental` 객체(없으면 `reading 'useFlatConfig'`). `useFlatConfig` 는 두지 않는다 — 서버가 ESLint 판(9 는 flat 기본)에 맞춰 알아보고, 넣으면 9 가 경고한다. 저장 시 고치기(`codeActionOnSave`)는 서버가 하지 않게 끈다 — §8.2s 의 kind 로 묻는다.
- **빈 객체**: Zig 의 빈 익명 리터럴 `.{}` 는 튜플이라 JSON `[]` 로 나간다(진짜 서버는 JS 라 배열도 객체로 받아 줘 안 보였다 — 가짜 서버가 객체를 요구해 드러났다). 이름 있는 빈 struct 로 낸다.
- **문서마다 languageId**: TS·TSX·JS 는 서버 하나를 나눠 쓰는데 didOpen 이 그 클라이언트를 세운 문서의 값을 보내, `.ts` 를 먼저 열면 `.tsx` 가 `typescript` 로 갔다(주 서버에도 있던 결함). 그 문서의 문법의 값을 보낸다(`servers.languageIdFor`).
- **가짜 ESLint**: 실행 파일 이름(argv[0])이 `vscode-eslint-language-server` 면 그 꼴로 선다(판정자가 저장소 `node_modules/.bin` 에 사본을 둔다). 실서버처럼 첫 pull 을 받으면 설정을 묻고 그 답을 받은 뒤에 답한다 — 처음엔 `initialized` 에 물어, 클라이언트가 설정 답보다 pull 을 먼저 보내는 순서에서 실서버와 달리 실패했다.

### 보이기

- 「Language Server: Show Server Info」에 그 문서의 보조 서버마다 한 줄(상태·루트 기준 설정 파일·실행 파일)을 **버전 줄 바로 뒤에** 더한다 — 알림은 6 행에서 끝부터 잘리므로 주 서버의 경로 줄보다 앞이다. 상태바는 주 서버 하나 그대로다.

## Biome·oxlint (AS4·AS5)

### 결정

- **같은 틀에 둘을 더한다**(2026-10-13 사용자 결정 「Biome·oxlint 는 같은 틀에 다음 조각으로」). 설정이 있을 때만·저장소 실행 파일 먼저·진단과 code action 만 — 앞의 결정을 그대로 따른다.
- **감지한 린터는 전부 띄운다**(AS4 에서 정한 것 — 「설정이 있을 때만」 결정을 도구마다 그대로 적용한 결과). 한 저장소에 ESLint·Biome·oxlint 설정이 함께 있으면(옮기는 중인 저장소 — `eslint-plugin-oxlint` 처럼 둘을 함께 쓰는 꼴이 흔하다) 셋 다 뜬다. 설정 파일이 저장소의 명시적인 선택이고, VS Code 도 확장마다 따로 돈다. 그래서 한 문서의 보조 서버 칸은 셋이다(`max_aux` 2 → 3).
- **Biome 의 JSON·CSS 는 다음 조각(AS5)이다.** 그 문법에는 주 서버 표가 없어 지금 동기화(`syncDocuments`)가 주 서버를 먼저 고르고 없으면 건너뛴다. AS4 는 JS·TS·TSX 만, AS5 가 「주 서버가 없는 문법의 보조 서버」를 연다.

### 실측 (2026-10-13, 임시 폴더에 설치 — Biome 2.5.15, oxlint 1.87.0)

| | Biome(`biome lsp-proxy`) | oxlint(`oxlint --lsp`) |
| --- | --- | --- |
| 진단 | **push**(didOpen 즉시) | **push**(didOpen 즉시) |
| 서버 → 클라이언트 요청 | `workspace/configuration`(`section: biome`) 둘·`client/unregisterCapability`·`client/registerCapability`(빈 목록) — **-32601 로 거부해도 진단·fix 가 돈다** | `workspace/configuration`(`section: oxc_language_server`) — 거부해도 돈다 |
| code action kind | `quickfix.biome`·`quickfix.suppressRule.{inline,topLevel}.biome`·`source.organizeImports.biome`·`source.fixAll.biome`·`refactor.*.biome`·`source.biome`(`resolveProvider`) | `quickfix`·`source.fixAll.oxc`·`source.fixAllDangerous.oxc`·`source.fixAll` |
| 줄 단위 quickfix | `data` 만(편집 없음) — **resolve 로 받는다**(`edit.changes`) | `edit`(규칙 fix·「이 줄 끄기」·「이 파일 끄기」) |
| fixAll | `source.fixAll` 을 물으면 `source.fixAll.biome` 하나(resolve) — **고친 뒤 포맷까지 한 본문**을 낸다(탭 들여쓰기·줄 나눔, 제품 경로 실측) | `source.fixAll.oxc` 하나(`edit.changes`) — safe fix 만 |
| 범위 | 문서 밖 범위면 `-32603 failed to access range` — 우리는 문서 끝까지라 해당 없음 | 범위 안의 진단만 고친다 — 문서 전체라 해당 없음 |
| 프로세스 | 프록시가 데몬(`biome __run_server --stop-on-disconnect`)을 **제 프로세스 그룹**으로 띄운다 — 우리 그룹 종료가 닿지 않는다. 마지막 프록시가 끊기면 스스로 내려간다(initialize 뒤 그룹 SIGTERM → 곧 사라짐, 실측). `initialize` 전에 죽인 프록시의 데몬은 남았다가 다음 세션이 끊길 때 함께 내려간다 | 프로세스 하나 |
| 설정 파일 | `biome.json`·`biome.jsonc` | `.oxlintrc.json`·`.oxlintrc.jsonc`·`oxlint.config.ts`·`oxlint.config.mts`(바이너리의 기본 탐색 목록) |
| languageId | 해석기를 languageId 로 고른다(CSS 를 `javascript` 로 보내면 JS 구문 오류). `.jsx` 는 `javascript` 로 보내도 JSX 로 읽는다 | — |
| 실행 파일 | `node_modules/.bin/biome`(node 실행 스크립트 → 플랫폼 바이너리) | `node_modules/.bin/oxlint`(node 실행 스크립트) — `--lsp` 는 1.x 의 플래그(옛 판은 인자를 몰라 끝나 「실패」로 선다) |

### 설계

- 보조 서버 표: JS·TS·TSX → ESLint·Biome·oxlint(그 순서 — 메뉴·저장 시 묻는 순서). `Tool` 에 `biome`·`oxlint`.
- 감지: Biome 은 외부 포매터의 `biome_config_names` 를 그대로 쓴다(두 벌이면 한쪽만 낡는다). oxlint 는 위 넷.
- 설정 답은 없다 — 둘 다 거부해도 돈다(§8.2a 의 거부 그대로; ESLint 만 예외).
- 정보 명령은 보조 서버마다 한 줄이라 셋이면 주 서버의 저장소·설정·경로 줄이 6 행 상한에 밀린다(끝부터 잘린다 — 받아들임).
- Biome 은 포매터(§8.2t)이기도 하다 — 포맷은 외부 포매터가 CLI(`biome format`)로, 린트는 보조 서버가. 둘은 따로 돈다.

### AS5 설계 메모

- **동기화**: `syncDocuments` 는 주 서버를 먼저 고르고 없으면 건너뛰었다. 이제 주 서버가 없어도 그 문법에 보조 서버 표가 있으면 root 를 풀고 보조 서버만 붙인다.
- **languageId**: `servers.languageIdFor` 가 주 서버 표가 없는 JSON·CSS 에 `json`·`css` 를 낸다(없으면 서버 표의 값 `javascript` 가 가서 Biome 이 JS 로 읽는다).
- **확장자 거름**: 문법 `.css` 는 `scss`·`less` 도 덮는다. Biome 은 그 둘을 다루지 않는다 — languageId `scss`·`less` 면 진단이 없고(빈 칸), `css` 면 `$c`·`@c` 에 거짓 구문 오류(실측). `Auxiliary.extensions` 로 `.css` 파일에만 붙인다(감지 단계 `auxiliariesFor` 에서 거른다 — 동기화·정보 줄이 모두 그 집합을 본다).
- **주 서버를 전제한 자리**: 정보 명령(`showServerInfo`)은 주 서버가 없으면 「없음」이었다 → 보조 서버 줄만. 신뢰 관리(`manageCurrent`)는 주 서버의 클라이언트로 결정을 찾았다 → 보조 서버의 클라이언트로(신뢰는 저장소 단위라 어느 클라이언트의 열쇠든 같다). 상태바(`statusFor`)·호버·이동 등 주 서버의 기능은 그대로 주 서버만 — 그 문서엔 없다.

## 조각

| 조각 | 내용 | 상태 |
| --- | --- | --- |
| AS1 | 구조 — 보조 서버 표·ruff 감지·`Client.role`·저장소 실행 파일·동기화·서버별 진단 칸·진단의 서버 이름(호버)·보조 응답 거름·정보 명령·계약 §8.2u | 완료 |
| AS2 | code action 을 서버 여럿에서 — `⌘.` 메뉴 합치기(첫 답 뒤 0.5 초)·resolve 를 그 서버로·저장 시 kind 를 알린 서버로·진단 `data`·`source` 왕복 | 완료 |
| AS3 | ESLint — 감지·`workspace/configuration` 고정 답·pull 진단(`20e8`)·refresh·문서마다 languageId | 완료 |
| AS4 | Biome·oxlint 를 JS·TS·TSX 에 — 표·감지·한 문서의 보조 서버 칸 셋 | 완료 |
| AS5 | 주 서버 표가 없는 문법의 보조 서버 — Biome 의 JSON·CSS(문서마다 그 문법의 languageId 가 필요하다 — Biome 은 languageId 로 해석기를 고른다: CSS 를 `javascript` 로 보내면 JS 구문 오류가 난다, 실측) | 완료 |

## 한계 (받아들일 것)

- 감지는 문서를 열 때 한 번이다(설정을 나중에 만들면 다시 열어야 한다).
- 보조 서버의 실행 파일은 그 클라이언트를 세운 문서 기준으로 찾는다 — 한 저장소에 `.venv` 가 여럿이면 처음 연 문서의 것을 쓴다(클라이언트가 `(root, exe)` 하나다).
- ESLint 의 줄 단위 quickfix·「이 줄 끄기」는 `command` 라 안 뜬다(fixAll 은 된다).
- 보조 서버가 셋이면 정보 명령의 주 서버 설정·경로 줄이 6 행 상한에 밀린다.
- Biome 의 데몬은 제 프로세스 그룹이라 `initialize` 전에 내린 프록시의 데몬이 다음 Biome 세션이 끊길 때까지 남는다.
- 원격(SSH) 문서는 언어 서버가 없다(§8.2a 그대로).

## 적대적 검증 (AS1, 5회)

1. 수명·상태 — 서버를 내릴 때 진단을 걷는 자리(`clearClientDiagnostics`)를 부르는 곳(거부·잊기·신뢰 대상 바뀜·전체 끄기)은 전부 **저장소 단위**라 같은 저장소의 클라이언트를 한꺼번에 걷는다 — 「그 서버 칸만」과 「전부」가 지금은 같다(변이 A19 등가, 자연스러운 대응이라 그대로 둔다). 진단이 든 서버 이름은 서버 표의 정적 문자열이라 클라이언트가 사라져도 산다.
2. 진짜 도구 — ruff 0.17.0 을 저장소 `.venv/bin` 에 두고 앱의 제품 경로로 돌렸다(임시 판정자, 커밋하지 않음): `server` 로 떠 `initialize`(서버 정보 `ruff 0.17.0`) → 진단 다섯(F401 둘·UP035·UP006·F821)이 ruff 칸에 바른 범위로, 주 서버(가짜) 진단은 제 칸에 그대로. 정보 명령 줄 「Lint server ruff — config pyproject.toml · .venv/bin/ruff」.
3. 문서 정합성 — §8.2a 의 「서버는 `(root, 언어)` 마다 하나」가 코드(`(root, 실행 파일)` 열쇠)와 달랐다 → 고침. 진단 합치기·호버 출처·§8.2t 의 「하지 않는 것」을 보조 서버로 이었다. 새 문서의 식별자를 코드와 기계로 대조했다(남은 것은 외부 API 이름·AS3 의 것).
4. 순서·신뢰 — 주 서버가 설치되지 않은 문서(보조 서버가 먼저 묻는다)·거부(같은 저장소라 함께)·`lsp.enabled` 끄고 켜기·`ruff server` 가 없는 옛 ruff(재시작 셋 뒤 「실패」, 정보 명령이 보인다)를 따라갔다 — 결함 없음. 외부 포매터 판정자(EXFB3)의 `.venv/bin/ruff`(가짜 포매터)가 이제 보조 서버로도 떠 인자 기록을 덮었다 — 제품에선 같은 ruff 가 포매터이자 보조 서버인 것이 맞으므로 가짜 포매터가 `server` 로 불리면 곧 끝나게 했다.
5. 변이 — 21개. 잡힘 17. 살아남은 넷: A14(「주 서버가 없으면 보조 서버만이라도」 조건 — 보조 서버가 있는 문법은 늘 주 서버 표가 있어 죽은 조건이었다 → 지웠다) · A17(보조 서버의 다시 고르기 막기)·A18(언어별 설정 블롭은 주 서버에만) — Python 만인 AS1 에선 등가, 주 서버 후보가 여럿인 TS 에 ESLint 가 붙는 AS3 에서 닿는다(코드 주석·AS3 판정자) · A19(위 1회차). A20(root 를 다시 풀 때 감지도 다시)은 처음 살아남아 `ASB2` 를 더해 잡았다. A6·A13·A19 는 처음 컴파일 오류로만 죽어 의미 변이로 다시 돌렸다. 순수 판정자(`AUX1·AUX2`)는 앱 테스트 루트에 들지 않아 처음 회차에서 돌지 않았다 — `src/_probe.zig` 루트로 따로 돌려 A21(`.ruff.toml`)을 잡았다.

## 적대적 검증 (AS2, 5회)

1. 상태·수명 — 기다리는 중 `⌘.` 를 다시 누름(새 seq 로 갈아 옛 응답을 버린다)·열린 메뉴가 빌린 제목(모으는 목록과 갈랐다)·첫 답 전에 서버가 죽음(서버 하나일 때처럼 기다린다)·주 서버가 준비되지 않은 문서의 저장(보조 서버만으로 돈다)을 따라갔다 — 결함 없음.
2. 진짜 도구 — ruff 0.17.0 을 제품 경로로(임시 판정자, 커밋하지 않음). **`⌘.` 메뉴에 ruff 의 줄 단위 fix 가 없었다** — `data` 만 되돌렸는데 ruff 는 문맥 진단의 `source` 가 `Ruff` 일 때만 낸다(드라이버로 셋을 갈라 확인: source+data → quickfix 둘, data 만·둘 다 없음 → fixAll·organize 만). → `source` 문자열도 들어 되돌린다(고침, `CAK4`·`LSP3`, 가짜 서버도 ruff 처럼 `source` 를 본다). 고친 뒤 메뉴에 「Ruff (F401): Remove unused import」·「Disable for this line」(edit)·「Fix all」·「Organize imports」(resolve)가 주 서버 항목 뒤에, 저장 시 `source.fixAll` 이 resolve 를 거쳐 쓰지 않는 import 둘을 지웠다.
3. 동작 변화의 근거 — 「알린 kind 만 묻는다」는 주 서버에도 적용된다. VS Code 도 저장 시 code action 에서 `providedCodeActionKinds` 가 요청 kind 와 위계로 겹치는 provider 에만 묻는다(동작만) — 같은 규칙이다. 실서버의 목록(typescript-language-server 의 `source.organizeImports.ts`·gopls 의 `source.organizeImports`)은 위계 양쪽 덮기로 그대로 묻힌다.
4. 순서·번호 충돌 — 메뉴와 저장 단계가 같은 클라이언트의 seq 를 나눠 쓰고, 다른 서버의 resolve 가 같은 번호일 수 있다. 두 단계 모두 (서버, seq) 로 가른다 — 결함 없음. 메뉴 항목 상한(25)은 주 서버가 먼저 채운다(받아들임).
5. 변이 — 21개. 처음 살아남은 일곱을 판정자를 더해 잡았다: B1·B13·B17·B20(응답을 서버 이름 없이 seq 로만 대조 — 두 서버의 첫 요청이 같은 번호라 판정자가 응답 순서를 못 정한다 → 실제 두 클라이언트로 입구를 직접 부르는 장면), B9(고른 항목을 주 서버로 resolve — 보조 항목이 모두 edit 을 들어 resolve 를 안 탔다 → 가짜 보조 서버의 `AUXLAZY`), B21(`source` 길이를 저장소 셈에서 뺌 — ArrayList 여유분 안이라 재할당이 안 났다 → 400 자), B8(시한 0 — 두 서버의 답이 같은 pump 에 읽혀 tick 이 끼지 못했다 → `AUXSLOW` 150ms). B8 은 처음 컴파일 오류로만 죽어 의미 변이로 다시 돌렸다. 21개 모두 잡혔다.

## 적대적 검증 (AS3, 5회)

1. 상태 — pull 답이 왔을 때 본문이 서버가 본 version 이 아니면 「다시 묻기」를 했는데, 그 경우는 아직 보내지 않은 편집(밀린 쓰기로 동기화가 미뤄진 사이)이라 **옛 version 으로 묻고 버리기를 보낼 때까지 되풀이**했다. → 버리기만 하고, 그 편집을 보낼 때 묻는다(고침). 서버가 죽으면 옛 프로세스의 pull 대기를 끝낸다(다시 띄울 때 — 아니면 「기다리는 중」이라 영영 안 묻는다).
2. 진짜 도구 — `vscode-langservers-extracted` 4.10 + ESLint 9.39 를 픽스처 저장소의 `node_modules` 로 걸고 제품 경로로(임시 판정자, 커밋하지 않음). **pull 이 `Cannot read properties of undefined (reading 'useFlatConfig')` 로 실패했다** — 설정에 `experimental` 객체가 없었다. → 넣었다(고침, `AUX4`; 가짜 ESLint 도 실서버처럼 그 객체를 요구한다). 그 과정에서 Zig 의 빈 익명 리터럴 `.{}` 가 JSON `[]` 로 나가 `options`·`experimental` 이 배열이었던 것도 드러났다(실서버는 JS 라 받아 줬다) → 이름 있는 빈 struct(고침). 고친 뒤: 진단 넷(no-var·prefer-const·no-undef 둘)이 ESLint 칸에 바른 범위로, 저장 시 `source.fixAll.eslint` 가 `var`·`let` 을 `const` 로, 정보 줄 「Lint server ESLint — config eslint.config.js · node_modules/.bin/vscode-eslint-language-server」. `⌘.` 메뉴엔 ESLint 항목이 없다 — 줄 단위 fix·「이 줄 끄기」·「모두 고치기」가 전부 `eslint.apply*` 명령이라 §8.2h ⑤ 가 숨긴다(받아들인 한계).
3. 문서 정합성 — §8.2a 의 「동기화」(languageId)·「하지 않는 것」(설정 답·refresh 예외), §8.2u 의 표·감지·실행 파일·pull·설정 답·하지 않는 것·관측점을 이었다. 계획의 id 칸 `17e8` 은 그 사이 다른 요청이 써서 `20e8`(i32 안의 마지막 칸)로 고쳤다.
4. 상호작용 — 주 TS 서버와 ESLint 가 같은 문서의 code action 을 받는다: `source.organizeImports` 는 ESLint 가 알리지 않아 가지 않고, `source.fixAll` 은 둘 다(VS Code 와 같다). 가짜 ESLint 를 처음엔 `initialized` 에 설정을 묻게 만들었다가, 클라이언트의 pull 이 설정 답보다 먼저 닿는 순서에서 실서버와 달리 실패했다 — 실서버처럼 첫 pull 에서 묻고 답을 받은 뒤 답하게 고쳤다.
5. 변이 — 21개. 처음 살아남은 넷을 판정자를 더해 잡았다: C5(답의 version 대조 빼기 — 같은 pump 안에서 보내기가 읽기보다 먼저라 판정자에서 그 순서가 안 생겼다 → 지난 version 으로 기다리는 pull 에 답을 직접 넣는 장면) · C12(다시 연 문서의 languageId — 재시작 뒤에도 `typescript`) · C17·C18(`diagnosticProvider` 확인·클라이언트 능력 — 가짜 ESLint 가 클라이언트가 pull 을 알렸을 때만 provider 를 내게 하고 provider 없는 장면 `ASB5`). 21개 모두 잡혔다.

## 적대적 검증 (AS4, 5회)

1. 상태 — 보조 서버 칸(`max_aux` 3)은 한 번 잡으면 놓지 않는다. 문서의 문법이 바뀌어 다른 문법의 칸이 남으면 셋째 서버의 진단이 조용히 빠질 수 있어 문법이 바뀌는 자리를 훑었다 — 이름 없는 문서를 처음 저장할 때(`untitled_save`)뿐이고, 이름 없는 문서는 서버가 붙지 않아 칸을 잡지 않는다. root 를 다시 풀어도 실행 파일 이름이 같아 같은 칸이다. 클라이언트 수에 매인 배열(`max_doc_clients`)은 모두 `max_aux` 에서 나온다 — 결함 없음.
2. 진짜 도구 — Biome 2.5.15·oxlint 1.87.0 을 픽스처 저장소의 `node_modules` 로 걸고 제품 경로로(임시 판정자, 커밋하지 않음). 두 서버가 저장소 실행 파일로 떠(서버 정보 `2.5.15`·`1.87.0`) 진단 열하나(Biome 일곱·oxlint 넷)가 제 칸에, 설정 답 0(둘 다 거부로 돈다). `⌘.` 를 `"fs"` 에서 — 주 서버 다음 Biome 의 「Apply unsafe fix for useNodejsImportProtocol」·「Suppress …」 둘(편집 없음) → 고르니 Biome 에 resolve 해 `"node:fs"`. `==` 에서 — Biome 셋 다음 oxlint 의 「Disable eqeqeq for this line」(편집) → `// oxlint-disable-next-line eqeqeq`. 저장 시 `source.fixAll` — Biome 이 `let`→`const`·`{ a: a }`→`{ a }` 에 **포맷까지** 한 본문을 냈다(설계 그대로 적용 — 서버의 편집이다; 실측 표에 적었다). 끝난 뒤 Biome 데몬이 남지 않았다.
3. 문서 정합성 — 계획의 「node 셈」 오타, 「감지한 린터는 전부」가 사용자 결정처럼 읽히던 것(이 조각에서 정한 것으로 밝혔다)을 고쳤다. §8.2u 의 표·띄우는 조건·실행 파일·설정 답·보이기·프로세스·하지 않는 것·관측점을 이었다.
4. 상호작용 — Biome 은 외부 포매터(§8.2t)이기도 하다: `⌘S` 는 저장 시 code action(Biome 의 fixAll — 포맷된 본문) 다음 포맷 단계(Biome CLI)라 두 번째는 바뀌는 것이 없다. Biome 이 `source.organizeImports.biome` 을 알려 저장 시 `source.organizeImports` 를 켜면 주 서버 다음 Biome 도 묻는다(VS Code 와 같다 — 뒤의 것이 이긴다). 한 진단에 Biome 항목이 셋이라 메뉴 상한(25)이 빨리 찬다 — 주 서버가 먼저 채운다(받아들임).
5. 변이 — 18개, 모두 잡혔다(컴파일 오류로 죽은 것 없음): 표 순서·빠짐·`.tsx` 만 빠짐·감지 이름 바꿔치기·이름 하나 빠짐·칸 둘·인자·설정 답 켬·설정 블롭·실행 폴더·표시 이름·`byExe` 빠짐·pull 켬·가장 가까운 것 대신 첫 폴더만·루트만·실행 파일 이름·칸 찾기 상한.

## 적대적 검증 (AS5, 5회)

1. 상태 — 이제 JSON·CSS 문서에도 `rootFor` 를 부른다(그 문법에 보조 서버 표가 있을 때만). 루트를 한 번 풀어 굳히는 일이고 부작용이 없다. 붙지 않은 문서(`.scss`)는 `seen` 에 들지 않아 닫기 처리와 어긋나지 않는다. 결정 전 저장소에서 JSON 을 처음 열면 Biome 이 신뢰를 묻는다 — 보조 서버가 주 서버 없이 뜰 때(AS1)와 같은 길이라 계약 §8.2u 「신뢰」에 적었다.
2. 진짜 도구 — Biome 2.5.15 를 픽스처 저장소에 걸고 제품 경로로(임시 판정자, 커밋하지 않음): JSON 의 키 중복(`noDuplicateObjectKeys`)·CSS 의 빈 블록·속성 중복이 바른 범위로 Biome 칸에 섰다(거짓 구문 오류 없음). `.scss` 엔 붙지 않았고 그 문서의 정보 명령은 「언어 서버를 쓰지 않는 문서」. 끝난 뒤 Biome 데몬이 남지 않았다.
3. 판정자 빈 곳 — 붙지 않은 문서의 정보 명령·신뢰 관리를 재는 장면이 없었다(같은 저장소에 Biome 클라이언트가 떠 있으면 신뢰 관리가 그것을 잡을 수 있다 — 감지 집합 확인이 막는다). ASB7 에 더했다. 판정자를 처음 쓸 때 확인 상자를 제품 경로와 다르게 닫아(컴포넌트의 `dismiss` 없이 취소만) 다음 `⌘.` 가 오버레이에 막혔다 — 판정자 쪽 잘못이라 제품 순서대로 고쳤다.
4. 상호작용 — 외부 포매터(§8.2t)는 JSON·CSS 에 Biome CLI 를 따로 쓴다(그대로). 주 서버가 없는 문서는 상태바 항목이 없어 Biome 이 「없음」·「거부」여도 상태바엔 안 보인다 — 정보 명령이 보인다(받아들인 한계, 계약 「하지 않는 것」).
5. 변이 — 16개, 모두 잡혔다(컴파일 오류로 죽은 것 없음): 확장자 거름(늘 참·대소문자·확장자 없음·`scss` 로)·표의 JSON 빠짐·CSS 에 거름 없는 Biome·languageId(`json`·`css`)·주 서버 없으면 건너뛰기·감지 단계의 거름 빠짐·정보 명령(「없음」으로·첫 줄바꿈·보조 서버 없음 확인)·신뢰 관리(보조 클라이언트 안 찾기·감지 집합 확인 빠짐)·주 서버 붙이기 막기. 감지 집합 확인 빠짐(E12)과 보조 서버 없음 확인 빠짐(E10)은 3회차에 더한 판정자가 잡는다.

## 검증

- 순수: 보조 서버 표, ruff·ESLint 감지(가장 가까운 설정·루트 밖은 안 봄·`[tool.ruff.lint]` 도 ruff), id 칸.
- 제품 경로(가짜 서버 — 보조 역할을 가를 수 있게): 한 문서에 두 서버가 뜨고 둘 다 didOpen·didChange 를 받음, 두 서버의 진단이 함께 보임, 한 서버의 publish 가 다른 서버의 것을 안 지움, 한 서버를 내리면 그 서버의 것만 걷힘, 호버가 진단마다 그 서버 이름, 보조 서버의 같은 seq 응답이 주 서버의 대기를 안 채움, 설정이 없으면 안 뜸, 저장소 실행 파일 먼저, 주 서버 없이도 뜸.
- 진짜 도구: ruff·ESLint·Biome·oxlint 를 임시 폴더에 받아 제품 경로로 한 번씩(임시 판정자, 커밋하지 않음).
