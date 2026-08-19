# 필수 프로젝트 규칙

Maru에서 작업하는 모든 에이전트와 개발자는 이 규칙을 따른다.

## 기본 규칙

- `.mise.toml`에 지정된 Zig 0.16.0을 사용한다.
- 외부 터미널/파서(Ghostty, GNOME vte, Alacritty, libvterm, xterm, kitty, WezTerm 등)는 `references/` 아래 read-only 참고 자료로만 사용한다. `references/`는 git에 커밋하지 않는 로컬 체크아웃이며, 레퍼런스 소스를 읽는 일은 이 경로에서만 한다. 공개 명세와 오라클을 무엇을 어디서 받는지는 [레퍼런스와 공개 명세](references.md)를 단일 출처로 둔다(`sh tools/fetch-references.sh`).
- 어떤 레퍼런스의 소스코드도 Maru에 복사하지 않는다. 특히 GNOME vte, kitty처럼 copyleft(LGPL/GPL) 라이선스인 레퍼런스는 구현 유도를 위해 소스를 열람하지 말고 최종 화면 동작 비교(오라클)로만 사용한다.
- Maru 터미널 코어의 "clean-room"은 공개 명세 기반 독립 재구현을 뜻한다. 구현은 ECMA-48, vt100.net DEC ANSI state machine, xterm ctlseqs 같은 공개 명세에서 유도하며, 레퍼런스의 코드 표현(자료구조 레이아웃, 함수/이터레이터 구조)을 그대로 옮기지 않는다. 이 원칙은 VT/parser뿐 아니라 renderer, storage, platform interop에도 적용한다. 레퍼런스별 허용 상호작용은 [오라클 비교 테스트 전략](oracle-testing.md#레퍼런스-라이선스와-허용-상호작용)을 따른다.
- **터미널 동작은 단일 표준이 없는 경우가 많다.** OSC 7(cwd)·OSC 133(semantic prompt)·OSC 52(clipboard) 등 상당수는 ECMA-48이 아니라 VTE·iTerm2·xterm·kitty가 각자 만든 사실상 표준이고 서로 미묘하게 다르다. 이런 동작을 추가·변경할 때는 **(1) 무엇을 베이스로 했는지**(공식 명세면 조항, 사실상 표준이면 누가 정의했고 어느 터미널이 채택했는지)와 **(2) 레퍼런스 간 동작이 갈릴 때 어느 쪽을 왜 택했는지**를 코드 주석·해당 docs 문서·PR 본문에 **모두** 남긴다. 근거 없이 동작을 고르지 않는다(예: `input.page-keys` 기본 `scroll`은 Terminal.app/iTerm2 관례를 택하고 xterm `passthrough`는 opt-in으로 둔 결정을 문서·PR에 기록). 베이스로 삼는 명세/오라클을 어디서 받는지는 [레퍼런스와 공개 명세](references.md)를 단일 출처로 둔다.
- 터미널 코어 API는 Maru 내부 facade 뒤에 둔다.
- `main`에 직접 푸시하지 않는다. 항상 브랜치와 PR을 사용한다.
- 커밋 메시지는 conventional-commit prefix(`feat`/`fix`/`docs`/`test`/`refactor`/`build`/`ci`/`chore`)를 쓴다.
- 브랜치 이름은 `type/kebab-설명` 형식을 쓴다(예: `refactor/surface-rename`).

## 의존성

- 런타임 의존성(`build.zig.zon`의 `dependencies`)은 기본 0으로 둔다. 새 런타임 의존성을 추가하려면 먼저 사용자와 논의한다.
  - **현재 예외 1건: tree-sitter**(편집기 syntax 1층 — 2026-08-09 사용자 논의를 거친 결정, [native-editor-visual-mapping.md](native-editor-visual-mapping.md) §5.3). 코어와 언어별 grammar가 바이너리에 링크되므로 라이선스·attribution은 [third-party 라이선스](third-party-licenses.md)가, 번들 언어 목록은 [네이티브 편집기 구현 계획](plans/native-editor.md)이 소유한다. **"기본 0"의 규율은 그대로다** — 이 예외가 다음 의존성의 선례가 되지 않는다.
- dev/test/CI 의존성(외부 오라클의 libvterm, Ghostty libghostty-vt, Alacritty alacritty_terminal 등)은 opt-in으로만 쓰고 기본 `mise run check` 경로에 넣지 않는다.
- 외부 reference를 추가하거나 필수 의존성으로 승격하는 규칙은 [레퍼런스와 공개 명세](references.md)·[오라클 비교 테스트 전략](oracle-testing.md)을 단일 출처로 둔다.
- 배포물(`.app`/`.dmg`)에 **번들·재배포하는 제3자 자산**(폰트 등)은 재배포·임베드가 허용된 라이선스만 쓰고, 라이선스 파일 동봉·원본 무수정·RFN 처리·attribution 갱신 규칙은 [third-party 라이선스](third-party-licenses.md)를 단일 출처로 둔다.

## 문서와 설명

- 새 코드에는 초보자가 의도를 이해할 수 있는 주석을 남긴다.
- 주석은 코드가 무엇을 하는지보다 왜 존재하는지를 설명해야 한다.
- 구현을 진행할 때마다 관련 문서가 실제 코드와 맞는지 확인한다.
- PR 설명, 문서 정합성, 코드가 문서와 달라졌을 때의 처리는 [PR 체크리스트](pr-checklist.md)를 단일 출처로 둔다. 같은 규칙을 이 문서에 중복해서 적지 않는다.

## 전략 유지

- 모든 PR은 기존 전략에 지장이 없는지 평가하고, 기존 전략을 수정해야 하면 임의로 바꾸지 말고 사용자와 먼저 논의한다.
- 한계를 숨기고 구현을 계속 밀어붙이지 않는다. 예상하지 못한 한계나 문서와의 차이가 드러나면 즉시 사용자에게 보고한다.
- PR 본문 양식, 전략 영향 평가 기준, 전략 수정 규칙, PR 메타데이터(라벨·assignee)는 [PR 체크리스트](pr-checklist.md)와 `.github/pull_request_template.md`를 단일 출처로 둔다.

## 버그 수정

- 버그는 증상이 아니라 루트커즈를 고친다.
- 구조가 원인이면 구조를 바꾼다.
- 임시 패치가 필요할 때도 왜 임시인지, 루트커즈 수정 계획이 무엇인지 보고한다.

## 리베이스와 머지

- **충돌은 발생한 커밋에서 고친다. 팁에서 고치지 않는다.** 팁에서만 고치면 작업 트리는 초록인데 **히스토리가 죽는다** —
  `git bisect`·커밋별 CI·그 지점 체크아웃이 전부 실패한다. 실제로 2026-08-18 리베이스에서 `build.zig` 의 게이트 등록
  블록 둘이 반쪽씩 섞인 채 커밋됐고, 팁에서만 고쳐 **9개 커밋(`5183f017`~`a8359346`)이 `zig build` 조차 안 되는 상태로
  `main` 에 남았다**(`error: expected field initializer`). 고친 트리를 보고 "됐다"고 판단한 것이 원인이다.
- **자동 해소를 믿지 않는다.** git 은 두 쪽이 **같은 블록의 다른 절반**일 때도 마커 없이 이어 붙인다. 그 결과는 마커
  검사(`tests/boundary/conflict_markers.zig`)도 `git status` 도 통과하고, **컴파일러만** 잡는다. 리베이스 뒤에는
  `git grep '^<<<<<<< '` 만으로 끝내지 말고 **반드시 빌드까지 돌린다**.
- **여러 커밋을 리베이스했으면 중간 커밋도 본다 — 문법이 아니라 게이트로 본다.** 앞 판은 여기에
  `zig ast-check` 를 적었는데, 그 문장을 **지키고도 같은 사고를 다시 냈다**: 2026-08-19 리베이스에서 digest
  원장 수렴을 팁 커밋 둘로 빼는 바람에 `0ed84382`·`ea0d3492` 두 커밋에서 `check-boundaries` 가 빨갛게 남았다.
  `ast-check` 는 문법·AstGen 만 보므로 **낡은 digest 를 원리적으로 못 잡는다.** 문법 검사는 규율의 값싼
  절반이고, 그 절반만 돌고 "확인했다" 고 적으면 안 잡히는 종류가 정확히 이것이다.
  중간 커밋을 체크아웃해 **`zig build check-boundaries` 까지** 돌린다(그것이 비싸면 최소한 원장을 건드린
  커밋들에 대해서만이라도).
- **digest 원장 수렴은 그것을 유발한 커밋에 넣는다.** 별도 "원장 맞추기" 커밋을 팁에 얹으면 그 앞 커밋들이
  전부 게이트 빨간 상태로 남는다 — 위 사고의 형태가 정확히 그것이다. 리베이스로 값이 또 움직이면
  `git rebase -i` 의 fixup 으로 **해당 커밋에 접어 넣는다**.
- 리베이스 뒤에는 **digest 원장을 다시 수렴시킨다**(`tests/boundary/external_source_digests.zig`). 안 하면 로컬은
  통과하고 CI 만 깨진다.
- **"확인했다" 고 적을 때는 무엇으로 확인했는지 적는다.** 위 두 사고 다 커밋 메시지에 "확인했다" 가 적혀
  있었고, 둘 다 **더 약한 검사**로 확인한 것이었다. 검사 이름을 적으면 그 약함이 리뷰에 보인다.

## 테스트와 E2E

- 동작을 구현 전에 표현할 수 있는 영역은 TDD를 기본값으로 둔다.
- 모든 테스트 파일은 그 테스트가 무엇을 증명하는지, 그리고 터미널에서 왜 중요한지 설명해야 한다.
- 모든 기능 영역에는 E2E 경로가 있어야 한다.
- 자동 E2E가 불가능한 영역은 완료 처리 전에 이유와 수동 검증 방법을 사용자에게 보고한다.
- terminal core, parser, renderer snapshot, PTY, workspace restore처럼 hot path나 반복 상태 변경이 있는 영역은 빠른 스트레스 테스트 또는 긴 soak 테스트 경로를 함께 고려한다.

## 관측 가능성

- 모든 기능은 처음부터 공통 관측 가능성을 고려해 설계한다.
- 디버그 이벤트, 구조화 로그, 스냅샷, 리플레이 trace, 테스트, 향후 inspector는 서로 다른 임시 포맷이 아니라 같은 도메인 데이터를 소비해야 한다.
- 기능 구현이나 버그 수정을 시작하기 전에 로그, 리플레이, 스냅샷, E2E 검증 경로를 먼저 정한다.
- 자동화 경로가 없으면 완료 처리 전에 한계로 보고한다.
- trace와 실패 산출물은 기본적으로 로컬 전용으로 둔다.
- 회귀 테스트 fixture로 추가할 때만 민감정보를 제거한 데이터를 git에 넣는다.

### 민감정보 redaction 기준 (단일 출처)

env override 저장, trace fixture, 실패 artifact는 모두 같은 redaction 기준을 쓴다. 포맷별로 키 목록을 따로 두지 말고 이 절을 단일 출처로 참조한다. 코드 미러는 중립 leaf `src/redact.zig`다(`sensitive_tokens`·`keyIsSensitive`·`hasSensitiveContent`·plain 가드 `guardFixture` — app/observability/config가 공유 import). **trace fixture는 output이 이벤트 경계로 쪼개지므로 `observability.trace.guardFixture`**(output 재조립 후 스캔)를 쓴다. 새 소비처는 새 목록을 만들지 말고 이 모듈을 import한다.

- key 이름에 다음 토큰이 들어가면(대소문자 무시, 부분 일치) 기본 redaction 대상이다: `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `COOKIE`, `KEY`, `AUTH`, `CREDENTIAL`, `SESSION`.
- redaction은 deny-by-default다. 위 목록은 최소 보장이며, 애매하면 남기지 말고 제거한다.
- `PATH`, `LANG`, `LC_*`처럼 명백히 안전한 값만 allowlist 후보로 둔다. allowlist는 구현 전에 사용자와 다시 확인한다.
- raw output bytes, cwd, command에 섞인 홈 디렉터리 경로·서버 주소·사용자 이름은 일반화하거나 익명화한다. trace는 `maru trace anonymize <in> [out]`(코드: `redact.anonymizeAlloc`·`observability.trace.anonymizeTrace`)이 홈 경로 세그먼트(`/Users/<X>/`→`/Users/user/`)·IPv4·`user@host.domain`·알려진 유저명을 자리표시자로 바꾼다(구조 보존 → 여전히 재생 가능). 이는 값 **일반화**이고, keyword-value secret(`TOKEN=…`) **차단**은 `guardFixture`가 맡는다(역할 분리).
- sanitize 후에도 같은 replay/restore 결과가 나오는지 확인한다(익명화는 멱등·구조 보존이라 재생성 유지).

## 구조와 파일 분리

- 확장 가능하고 책임 경계가 명확한 구조를 유지한다.
- 한 모듈이 서로 무관한 책임을 갖기 시작하면 플래그를 추가하지 말고 모듈을 분리한다.
- 파일도 가능한 한 목적별로 나눈다.
- 하나의 파일이 parser, storage, encoding, logging처럼 서로 다른 이유로 변경되기 시작하면 facade는 유지하되 구현 파일을 목적별로 분리한다.
