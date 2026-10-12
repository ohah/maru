# 외부 포매터 구현 계획

상태: EF1 완료, EF2 대기. 계약은 [tooling §8.2t](../editor-surface-tooling.md)가 소유하고, 이 문서는 결정·설계·조각·검증을 소유한다. 도구 실행의 공통 계약은 §8.1 이다.

## 왜

저장 시 포맷(§8.2r)과 문서 포맷(`⇧⌥F` — §8.2e)은 언어 서버를 거쳐서만 된다. 그래서 두 구멍이 있다.
- **JS/TS**: TS 서버의 내장 포매터가 돌아 Prettier 설정을 따르지 않는다. 저장 시 포맷이 기본으로 켜져 있어, Prettier 를 쓰는 저장소에서 `⌘S` 가 Prettier 와 다른 스타일로 바꿔 diff 를 만든다.
- **Python**: pyright 에는 포맷 기능이 없어 black·ruff 가 돌지 않는다.

§8.1 은 외부 도구 실행의 선행 조건으로 저장소 신뢰를 두었고, [워크스페이스 신뢰 계획](workspace-trust.md)이 그것을 끝냈다.

## 결정 (2026-10-12 사용자, 모두 권장안)

- **저장소 설정을 감지하고 설정으로 덮는다.** 저장소가 고른 포매터를 따른다 — Prettier 설정과 실행 파일이 있으면 Prettier, Python 은 ruff·black 설정을 본다. 언어별 설정으로 덮거나 끌 수 있다. 「설정에 적은 명령만」 안은 고르지 않았다(Prettier 저장소마다 설정해야 하고 그전엔 TS 내장 포매터가 돈다).
- **실행 파일은 저장소 안 먼저, 없으면 PATH.** `node_modules/.bin/prettier`·`.venv/bin/ruff` 처럼 저장소가 고정한 버전이 CI 와 같은 결과를 낸다. Prettier 확장·Zed 와 같은 순서다.
- **첫 범위는 Prettier + ruff/black + 사용자 명령**, 조각 둘로 나눈다(실행 경로·Prettier 먼저).
- **`⌘S` 와 `⇧⌥F` 둘 다** 외부 포매터를 쓴다(두 길이 같은 결과를 낸다).

## 설계

### 언제 무엇을 쓰나 (순수 층 `session/editor/external_format.zig`)

- 설정 `editor.formatter.<언어>`(언어는 문법 이름 — `typescript`·`javascript`·`tsx`·`json`·`css`·`html`·`markdown`·`python` …)의 값.
  - `auto`(기본): 저장소 설정을 감지한다. 아니면 언어 서버.
  - `lsp`: 언어 서버만(지금 동작).
  - `off`: 포맷하지 않는다(`⌘S` 는 곧바로 저장, `⇧⌥F` 는 알림).
  - `prettier`(EF1)·`ruff`·`black`(EF2): 감지 없이 그 포매터.
  - 사용자 명령(EF2).
- **Prettier 감지**(`auto`, Prettier 가 다루는 문법 — JS·TS·TSX·JSON·CSS·HTML·Markdown): 문서 폴더에서 저장소 루트까지 올라가며 가장 가까운 Prettier 설정을 찾는다.
  - 파일: `.prettierrc`, `.prettierrc.{json,json5,yaml,yml,toml,js,cjs,mjs,ts,cts,mts}`, `prettier.config.{js,cjs,mjs,ts,cts,mts}`.
  - `package.json` 의 최상위 `"prettier"` 키(상한을 둔 읽기 + JSON).
  - 설정이 있으면 Prettier 다. 실행 파일이 없으면 포맷하지 않고 알린다(「Prettier 설정이 있지만 실행 파일이 없습니다 — npm install」). 언어 서버로 물러서면 Prettier 와 다른 스타일로 바꾼다.
- **실행 파일**: 문서 폴더에서 루트까지 올라가며 가장 가까운 `node_modules/.bin/prettier`(모노레포). 없으면 저장소 셸 환경(`tool_env.rootView`)의 PATH 에서 `prettier`.
- **argv**: `prettier --stdin-filepath <문서 경로>`. 셸 없이 실행하고, cwd 는 저장소 루트, 환경은 언어 서버와 같은 `rootView.envp` 다(제외 목록 포함). Prettier 가 경로로 설정·ignore·파서를 고른다(ignore 된 파일은 입력을 그대로 낸다 — 무변경).

### 신뢰

- 외부 포매터는 **신뢰한 저장소에서만** 돈다(`lsp.repoTrusted`). 실행 파일이 PATH 의 것이어도 같다 — Prettier 는 저장소의 `prettier.config.js`·플러그인(JS)을 실행한다(§8.1 「config/plugin/binary」).
- 신뢰 전·거부·묻지 않는 root:
  - `⌘S` 는 포맷 없이 저장한다. 저장이 시트 때문에 막히지 않는다(§8.2r 의 「서버가 없으면 곧바로 저장」과 같다).
  - `⇧⌥F` 는 사용자가 포맷을 직접 부른 것이라, 결정이 없으면 저장소 신뢰 시트(`askTrustForRepo`)를 띄운다. 거부·묻지 않는 root 면 그 이유를 알린다.

### 실행기 (플랫폼 `platform/macos/format_process.zig`)

- 작업 스레드 하나가 한 번 실행한다. 메인은 `editor_lsp.pump` 의 tick 에서 결과를 가져간다(`tool_env` 와 같은 모양 — 결과 칸 + 뮤텍스, 세대).
- fork + execve(`std.process.run` 은 앱 Io 에서 못 쓴다). 자식은 `setpgid(0,0)`, stdin·stdout·stderr 는 파이프, fd 3 이상은 닫고 `chdir(root)` 한다.
- 부모는 `poll` 로 stdin 쓰기와 stdout·stderr 읽기를 함께 돈다(하나씩 읽으면 막힌다). 시한은 단조 시계로 잰다.
- **상한**: 시한 3 초(Node 첫 실행이 1 초를 넘는다 — §8.2r 의 1 초는 떠 있는 서버의 응답 시한이다), stdout 16 MiB, stderr 64 KiB. 넘으면 그룹째(`kill(-pid)`) 끝내고 거둔다.
- 결과: 종료 코드, stdout, stderr 앞부분. 0 이 아니면 실패다(stderr 첫 줄을 알림에 싣는다).

### 결과 적용

- 시작 때 문서 revision(`lsp_version`)을 든다. 결과가 왔을 때 다르면 버린다(§8.2e 의 낡음 규칙).
- 결과 본문과 지금 본문의 **줄 대응(`diff.zig`)으로 덩어리마다 `Change`** 를 만든다. 덩어리 하나로 합치면 그 사이 커서가 첫 변경 자리로 끌려간다. `applyEditAsOneWithUndo` 로 되돌리기 하나다. 같으면 무변경이다.
- 저장 시: 적용(또는 버림·실패) 뒤 `format.saveNow(late)` — §8.2r 과 같은 저장·알림 길. 시한이면 포맷 없이 저장하고 알린다.
- 저장 시 code action(§8.2s)은 그대로 먼저 돈다(언어 서버의 것). 그 뒤 포맷 단계가 외부 포매터를 고른다.

### 보이기

- 팔레트 「Editor: Show Formatter Info」 — 지금 문서의 포매터(감지한 설정 파일·설정), 저장소와 신뢰, 실행 파일(저장소 안인지). 「Language Server: Show Server Info」에 줄을 더하지 않은 이유: 그 명령은 언어 서버가 없는 문법(Markdown·CSS·JSON)에서 일찍 돌아오고, 알림이 6 행에서 끝부터 잘린다.
- 실패 알림: 「Prettier 가 실패했습니다: ‹stderr 첫 줄›」, 시한, 실행 파일 없음.
- 앱 로그 `format` 범위에 실행마다 한 줄(실행 파일·종료 코드·걸린 시간).

## 조각

| 조각 | 내용 | 상태 |
| --- | --- | --- |
| EF1 | 실행기·Prettier 감지·설정 키 `editor.formatter.<언어>`(`auto`·`lsp`·`off`·`prettier`)·`⌘S`·`⇧⌥F`·줄 대응 편집·신뢰·정보 명령·계약 §8.2t | 완료 |
| EF2 | Biome·oxfmt(JS 계열 — 여럿이면 알림)·ruff·black(Python)·rustfmt·zig fmt(언어 서버가 포맷 못 할 때)·사용자 명령(`command:`) — 아래 「EF2 결정」 | 대기 |

## EF2 결정 (2026-10-12 사용자)

사용자가 Prettier 밖의 도구(oxfmt·Biome·rustfmt·clippy·zig fmt)를 물었고, EF2 의 범위를 넓혔다.

- **JS 계열(Prettier·Biome·oxfmt)이 함께 있으면 알리고 설정을 요구한다**(사용자가 권장안 「가장 가까운 설정 → 같으면 Biome>oxfmt>Prettier」 대신 골랐다). 문서 폴더에서 저장소 루트까지 서로 다른 도구의 설정이 둘 이상 보이면 포맷하지 않고 「‹도구들› 설정이 함께 있습니다 — `editor.formatter.<언어>` 로 고르세요」를 알린다. `⇧⌥F` 는 누를 때마다, `⌘S` 는 그 문서에서 한 번만 알리고 포맷 없이 저장한다(저장마다 알리면 성가시다 — 구현이 정한 것). 하나뿐이면 그것이다.
  - Biome: `biome.json`·`biome.jsonc` → `biome format --stdin-file-path=<경로>`. 보호 파일(`tsconfig.json` 등)에서 빈 stdout 을 낸다 — EF1 의 「빈 결과는 받지 않는다」가 지킨다.
  - oxfmt(베타): `.oxfmtrc.json`·`.oxfmtrc.jsonc` → `oxfmt --stdin-filepath <경로>`.
- **Python 은 포맷 설정이 있는 쪽**(권장안): `[tool.ruff.format]`·`ruff.toml`/`.ruff.toml` 의 `[format]` 이 있으면 ruff, 아니면 `[tool.black]` 이 있으면 black, 그것도 없고 ruff 설정만 있으면 ruff. ruff 를 린터로만 쓰고 포맷은 black 인 저장소를 따른다. `ruff format --stdin-filename <경로> -`·`black --stdin-filename <경로> -`. 실행 파일은 가장 가까운 `.venv/bin`·`venv/bin`, 없으면 PATH. TOML 해석기는 없어 표 머리(`[tool.ruff.format]` 등)를 줄 단위로 찾는다.
- **rustfmt·zig fmt 는 언어 서버가 포맷 못 할 때만 직접**(권장안): rust-analyzer·zls 가 떠서 포맷할 수 있으면 지금처럼 언어 서버(같은 도구를 부른다), 없거나 준비 전이면 `rustfmt --emit stdout`(cwd 루트 — `rustfmt.toml`·edition 은 `Cargo.toml` 에서 읽게 `--edition` 을 넘길지 실측으로 정한다)·`zig fmt --stdin`.
- **사용자 명령은 `command:` 앞에 argv**(권장안): `editor.formatter.go = command: gofumpt`. 공백으로 가르고 큰따옴표로 묶으며 `{path}` 가 문서 경로로 바뀐다. 셸 없이 실행하고 stdin→stdout 규칙은 같다. 머리를 두어 내장 이름이 늘어도 안 겹친다.
- **clippy 는 이 계획 밖**: 린터이고 고치기(`cargo clippy --fix`)가 크레이트 전체의 디스크 파일을 고쳐 「그 문서만」 규칙에 맞지 않는다. 린트 수정(보조 언어 서버·rust-analyzer 의 check 명령)과 함께 따로 다룬다.
- **실측**: 각 도구를 임시 폴더에 받아 진짜로 돌린다(EF1 은 Prettier 3.3.3 으로 TS 를 쟀다).

## 한계 (받아들일 것)

- 외부 포매터는 문서 전체를 포맷한다(범위 포맷 없음).
- 원격(SSH) 문서는 포맷하지 않는다(언어 서버도 없다).
- 이름 없는 문서는 경로가 없어 감지하지 않는다(`auto` 는 언어 서버, `prettier` 를 적었으면 경로 없이 확장자로 파서를 고르게 한다 — EF1 은 포맷하지 않고 알린다).
- OS 샌드박스는 없다 — 도구는 사용자 권한으로 저장소 밖에도 닿는다(§8.1, 신뢰 시트가 말한다).

## 검증

- 순수: 설정 값 읽기, Prettier 감지(가장 가까운 설정·`package.json` 키·루트 밖은 안 봄), 실행 파일 고르기, argv, 줄 대응 → `Change` 덩어리.
- 플랫폼: 실행기 — 가짜 포매터(빌드가 내는 테스트 전용 실행 파일)로 stdin→stdout, 큰 입력(파이프 버퍼보다 큼), 시한(그룹째 끝냄·좀비 없음), stdout 상한, 0 이 아닌 종료와 stderr, 실행 파일 없음.
- 제품 경로: `⌘S`·`⇧⌥F` 가 Prettier 감지 저장소에서 가짜 포매터를 부르고 덩어리마다 적용하며 커서를 지킴, 언어 서버 포맷을 부르지 않음, 신뢰 전이면 포맷 없이 저장·`⇧⌥F` 는 시트, 낡은 revision, 시한 뒤 저장, `off`·`lsp`.

## 적대적 검증 (EF1, 5회)

1. 수명 — 외부 포매터를 기다리는 중에 창이 닫히면 그 결과가 앱 전역 결과 목록에 영영 남았다. → 창을 닫을 때 기다리던 실행을 버린다(`format.deinit` — 고침, 변이 C26).
2. 상태와 알림 — 외부 포매터·셸 환경을 기다리던 `⌘S` 가 저장 시한에 걸리면 「언어 서버가 시간 안에 포맷하지 않았다」고 알렸다. → 그 포매터의 이름으로 알린다(환경 준비 중에도 종류를 든다 — 고침, 변이 C25).
3. 진짜 Prettier — Prettier 3.3.3 으로 TS·TSX·JS·JSON·CSS·HTML·Markdown 을 돌려 `--stdin-filepath` 의 파서 고르기·`.prettierignore` 의 무변경(입력 그대로·0)·구문 오류(2)를 쟀다. 오류 첫 줄이 `[error] ‹전체 경로›: SyntaxError…` 라 알림 상한에서 오류가 잘렸다. → 머리 표식과 문서 경로를 뗀다(고침, `EXFL1`·변이 C22). 앱의 제품 경로로도 진짜 Prettier 를 한 번 돌렸다(정보 명령·`⇧⌥F` 적용 — 임시 판정자, 커밋하지 않음).
4. 문서 정합성 — 설정 문서의 `editor.format-on-save`·`⇧⌥F` 줄과 계약 §8.2r 이 「언어 서버의 포맷」만 말했다. → 외부 포매터로 이었다(고침).
6. (EF2 를 만들다 찾음) 막 연 문서 — 낡음을 `lsp_version` 으로 쟀는데, 그 값은 언어 서버가 문서를 열 때(didOpen) 0 → 1 로 오른다. 파일을 열자마자 `⌘S`·`⇧⌥F` 를 누르면 외부 포매터가 도는 사이 언어 서버가 열어 멀쩡한 결과를 버렸다(EF1 판정자는 언어 서버가 연 뒤에만 포맷해 안 보였다). → 편집기의 본문 revision(`opened.file.revision`)으로 잰다(고침, `EXFB1` ⑴-b — 옛 비교로 되돌리면 잡힌다).
5. 변이 — 30개. 살아남은 둘(C20 빈 결과 받음·C29 도구 환경 대신 앱 환경)은 판정자를 더해 잡았다(가짜 포매터의 `FMTEMPTY`·셸 환경을 담기 시작한 뒤 앱 환경에 넣은 변수가 자식에 안 감 — 판정자 빌드의 셸 없는 갈래는 살아 있는 앱 환경을 그대로 주어 그 축을 못 가르므로 가짜 로그인 셸 판정자 EXFB2 에서 잰다). 셋(C1·C30 컴파일 오류, C9 무한 루프)은 의미 변이로 다시 써 돌렸다. 30개 모두 잡혔다.
