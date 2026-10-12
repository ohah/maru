# 보조 언어 서버 구현 계획

상태: AS1 진행(구조·ruff 진단). 계약은 [tooling §8.2u](../editor-surface-tooling.md)가 소유하고, 이 문서는 결정·설계·조각·검증을 소유한다. 언어 서버의 공통 계약은 §8.2a 다.

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
- pull 진단(AS3): `diagnosticProvider` 가 있고 push 를 안 하는 서버(ESLint)에는 보조 클라이언트의 `initialize` 에 `textDocument.diagnostic` 능력을 알리고, 문서를 보낼 때마다(didOpen·didChange 뒤, 같은 묶음 규칙) `textDocument/diagnostic`(id 칸 `17e8`)을 묻는다. 응답의 `kind: full` 은 그 서버 칸을 갈아 끼우고 `unchanged` 는 그대로 둔다. 물은 뒤 문서가 바뀌었으면 버린다. 주 서버에는 알리지 않는다(tsgo 등이 push 에서 pull 로 바꾸면 지금 동작이 바뀐다).

### code action (AS2)

- `⌘.` 메뉴: 주 서버와 보조 서버 각각에 묻고(서버마다 자기 진단을 문맥으로), 응답을 **모두 받거나 시한**이 되면 합쳐 낸다(주 서버 먼저). 항목은 그 서버를 기억한다 — resolve 는 그 서버에 보낸다.
- 저장 시 code action: 설정 kind 마다 그 kind 를 지원하는(`codeActionKinds` 가 덮는 — `source.fixAll` 은 `source.fixAll.eslint` 를 덮는다) 서버에 차례로 묻는다(주 서버 먼저). 하나를 적용하면 revision 이 올라 다음 요청이 새 본문을 본다(§8.2s 그대로).
- ESLint 의 줄 단위 quickfix 는 `command` 만이라 메뉴에 안 뜬다(§8.2h ⑤ 그대로). `workspace/executeCommand`·`workspace/applyEdit` 는 이 계획 밖이다.

### 서버 → 클라이언트 요청 (AS3)

- §8.2a 는 서버 요청을 전부 거부한다. 예외를 하나 더한다: **`workspace/configuration` 에 서버 표의 고정 설정으로 답한다**(그 서버에 정해 둔 블롭이 있을 때만 — ESLint; 없으면 지금처럼 거부). 읽기 요청이고 답은 우리 상수라 승인 UI 가 필요한 「행동」이 아니다.
- `client/registerCapability` 는 지금처럼 거부한다(ESLint 는 작업 폴더 변경 알림만 등록하려 한다 — 거부돼도 진단·fix 는 돈다; AS3 에서 실측으로 확인).

### 보이기

- 「Language Server: Show Server Info」에 그 문서의 보조 서버마다 한 줄(상태·루트 기준 설정 파일·실행 파일)을 **버전 줄 바로 뒤에** 더한다 — 알림은 6 행에서 끝부터 잘리므로 주 서버의 경로 줄보다 앞이다. 상태바는 주 서버 하나 그대로다.

## 조각

| 조각 | 내용 | 상태 |
| --- | --- | --- |
| AS1 | 구조 — 보조 서버 표·ruff 감지·`Client.role`·저장소 실행 파일·동기화·서버별 진단 칸·진단의 서버 이름(호버)·보조 응답 거름·정보 명령·계약 §8.2u | 진행 |
| AS2 | code action 을 서버 여럿에서 — `⌘.` 메뉴 합치기·resolve 를 그 서버로·저장 시 kind 를 지원 서버로 | 대기 |
| AS3 | ESLint — 감지·`workspace/configuration` 고정 답·pull 진단(`17e8`)·`eslint/*` 알림 | 대기 |

## 한계 (받아들일 것)

- 감지는 문서를 열 때 한 번이다(설정을 나중에 만들면 다시 열어야 한다).
- 보조 서버의 실행 파일은 그 클라이언트를 세운 문서 기준으로 찾는다 — 한 저장소에 `.venv` 가 여럿이면 처음 연 문서의 것을 쓴다(클라이언트가 `(root, exe)` 하나다).
- ESLint 의 줄 단위 quickfix·「이 줄 끄기」는 `command` 라 안 뜬다(fixAll 은 된다).
- 원격(SSH) 문서는 언어 서버가 없다(§8.2a 그대로).

## 적대적 검증 (AS1, 5회)

1. 수명·상태 — 서버를 내릴 때 진단을 걷는 자리(`clearClientDiagnostics`)를 부르는 곳(거부·잊기·신뢰 대상 바뀜·전체 끄기)은 전부 **저장소 단위**라 같은 저장소의 클라이언트를 한꺼번에 걷는다 — 「그 서버 칸만」과 「전부」가 지금은 같다(변이 A19 등가, 자연스러운 대응이라 그대로 둔다). 진단이 든 서버 이름은 서버 표의 정적 문자열이라 클라이언트가 사라져도 산다.
2. 진짜 도구 — ruff 0.17.0 을 저장소 `.venv/bin` 에 두고 앱의 제품 경로로 돌렸다(임시 판정자, 커밋하지 않음): `server` 로 떠 `initialize`(서버 정보 `ruff 0.17.0`) → 진단 다섯(F401 둘·UP035·UP006·F821)이 ruff 칸에 바른 범위로, 주 서버(가짜) 진단은 제 칸에 그대로. 정보 명령 줄 「Lint server ruff — config pyproject.toml · .venv/bin/ruff」.
3. 문서 정합성 — §8.2a 의 「서버는 `(root, 언어)` 마다 하나」가 코드(`(root, 실행 파일)` 열쇠)와 달랐다 → 고침. 진단 합치기·호버 출처·§8.2t 의 「하지 않는 것」을 보조 서버로 이었다. 새 문서의 식별자를 코드와 기계로 대조했다(남은 것은 외부 API 이름·AS3 의 것).
4. 순서·신뢰 — 주 서버가 설치되지 않은 문서(보조 서버가 먼저 묻는다)·거부(같은 저장소라 함께)·`lsp.enabled` 끄고 켜기·`ruff server` 가 없는 옛 ruff(재시작 셋 뒤 「실패」, 정보 명령이 보인다)를 따라갔다 — 결함 없음. 외부 포매터 판정자(EXFB3)의 `.venv/bin/ruff`(가짜 포매터)가 이제 보조 서버로도 떠 인자 기록을 덮었다 — 제품에선 같은 ruff 가 포매터이자 보조 서버인 것이 맞으므로 가짜 포매터가 `server` 로 불리면 곧 끝나게 했다.
5. 변이 — 21개. 잡힘 17. 살아남은 넷: A14(「주 서버가 없으면 보조 서버만이라도」 조건 — 보조 서버가 있는 문법은 늘 주 서버 표가 있어 죽은 조건이었다 → 지웠다) · A17(보조 서버의 다시 고르기 막기)·A18(언어별 설정 블롭은 주 서버에만) — Python 만인 AS1 에선 등가, 주 서버 후보가 여럿인 TS 에 ESLint 가 붙는 AS3 에서 닿는다(코드 주석·AS3 판정자) · A19(위 1회차). A20(root 를 다시 풀 때 감지도 다시)은 처음 살아남아 `ASB2` 를 더해 잡았다. A6·A13·A19 는 처음 컴파일 오류로만 죽어 의미 변이로 다시 돌렸다. 순수 판정자(`AUX1·AUX2`)는 앱 테스트 루트에 들지 않아 처음 회차에서 돌지 않았다 — `src/_probe.zig` 루트로 따로 돌려 A21(`.ruff.toml`)을 잡았다.

## 검증

- 순수: 보조 서버 표, ruff·ESLint 감지(가장 가까운 설정·루트 밖은 안 봄·`[tool.ruff.lint]` 도 ruff), id 칸.
- 제품 경로(가짜 서버 — 보조 역할을 가를 수 있게): 한 문서에 두 서버가 뜨고 둘 다 didOpen·didChange 를 받음, 두 서버의 진단이 함께 보임, 한 서버의 publish 가 다른 서버의 것을 안 지움, 한 서버를 내리면 그 서버의 것만 걷힘, 호버가 진단마다 그 서버 이름, 보조 서버의 같은 seq 응답이 주 서버의 대기를 안 채움, 설정이 없으면 안 뜸, 저장소 실행 파일 먼저, 주 서버 없이도 뜸.
- 진짜 도구: ruff·ESLint 를 임시 폴더에 받아 제품 경로로 한 번씩(임시 판정자, 커밋하지 않음).
