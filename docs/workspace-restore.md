# Workspace Restore 전략

이 문서는 Maru의 workspace restore가 무엇을 저장하고, 무엇을 저장하지 않는지 정한다.

## 초보자용 설명

workspace restore는 "실행 중이던 shell process를 그대로 냉동했다가 다시 살리는 기능"이 아니다.

운영체제의 process, PTY file descriptor, foreground job은 앱을 끄면 사라진다. 이것을 그대로 저장할 수 없다.

Maru가 저장하는 것은 다시 시작하기 위한 **설명서**다.

```text
저장하는 것:
  repo root
  tab/surface layout
  각 surface의 cwd
  각 surface의 shell_entry
  사용자가 명시한 startup_recipe
  사용자가 명시한 safe env overrides
  claude/codex 세션 resume 정보(opt-in — agent_kind·session_id·보존 argv; 아래 allowlist 절)

저장하지 않는 것:
  live PTY handle
  child process id
  임의의 전체 env dump
  임의 명령의 last_observed_command 자동 재실행 정보(claude/codex는 allowlist 예외 — 아래 절)
```

## 자동 복구와 명령 재실행은 다르다

이 절의 보안 정책은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md#workspace-restore와-command-restore)을 따른다.

가장 위험한 설계는 "마지막으로 실행 중이던 명령을 앱 재시작 시 자동으로 다시 실행"하는 것이다.

예를 들어 사용자가 실수로 다음 명령을 실행 중이었다고 하자.

```sh
rm -rf tmp/build
deploy-prod
```

workspace restore가 이것을 자동 재실행하면 위험하다.

초기 정책:

- 자동 restore는 layout, cwd, shell 시작까지만 한다.
- 임의의 마지막 command나 shell integration으로 관측한 `last_observed_command`는 자동 재실행하지 않는다.
- repo별 기본 command는 사용자가 `startup_recipe`로 명시한 경우에만 실행 후보가 된다.
- destructive할 수 있는 `startup_recipe` 자동 실행은 나중에 confirmation이나 allowlist가 필요하다.

## 에이전트 세션 자동 resume (claude/codex allowlist 예외)

위 "임의 명령 자동 재실행 금지"의 **명시적 예외**다. claude·codex는 자체 resume 기능을 가진 안전한 에이전트라,
opt-in 토글이 켜졌을 때 종료 전 세션을 자동으로 다시 연다. 임의 셸 명령(`rm -rf`·`deploy-prod`) 재실행과 본질이
다르다 — 에이전트 resume은 "직전 대화를 다시 연다"이지 "부수효과 명령을 재실행"이 아니다. claude `--resume <id>` /
codex `resume <id>`는 그 도구가 설계한 정상 재개 경로다.

### 무엇을 저장하나

- `agent_kind`: `claude` | `codex`(그 외는 일반 셸 복원).
- `session_id`: 그 페인 에이전트의 세션 식별자. **새로 만들지 않고 이미 디스크에 있는 값을 읽는다** — 종료 시점에
  **훅 매핑**(`readMapping(surface.id)` → 정확한 `transcript_path`)에서 뽑는다(`sessionIdFromTranscript`): claude는
  파일명 `<uuid>.jsonl`, codex는 첫 줄 `session_meta.payload.id`. 훅이 팬별 경로를 정확히 주므로 cwd+mtime 추측이 없다
  (docs/agent-session.md "세션 파일 찾기 = 훅 매핑"). 매핑이 없으면 빈 값 → 아래 폴백.
- 보존 `argv`: 종료 시점 에이전트의 전체 argv. `--resume`이 권한 모드를 복원하지 않으므로(아래), 직전 플래그를
  재현하려면 argv가 필요하다.

### 다중 세션과 session_id

같은 cwd에 세션이 여럿이면 claude `--continue`·codex `resume --last`는 "가장 최근 1개"만 잡는다. 그 페인들을 모두
`--continue`로 복원하면 여러 프로세스가 한 transcript에 동시에 써서 대화가 뒤섞인다. 그래서 **session_id 단위로
정확히** 복원한다(`--resume <id>` / `resume <id>`). **훅 매핑이 페인마다 정확한 세션 경로를 주므로**, 옛 cwd+mtime
추측(가장 최근 파일을 골라 다중 세션에서 엉뚱한 세션을 잡던 문제)이 사라졌다 — 각 페인이 자기 session_id로 복원된다.
매핑을 못 얻으면(훅 미발화·미설정) session_id가 빈 값이 되어 `--continue` / `resume --last`로 graceful degrade한다
(가장 최근 1개 — 다중 세션이면 부정확하나 세션을 잃지는 않는다).

### 위험모드(권한 플래그) 재현

claude `--resume`은 대화만 복원하고 `--dangerously-skip-permissions` 같은 권한 모드는 복원하지 않는다(런타임
플래그라 세션에 저장되지 않음). 저장한 argv를 재주입해 직전 권한 모드를 그대로 재현한다. 이는 **새 위험을 만드는
게 아니라 직전 상태 복원**이다 — 그래서 토글 기본값을 OFF(opt-in)로 두어 위험모드 자동 재현을 사용자가 명시적으로
켜게 한다.

### redaction 경계

- `session_id`는 자격증명이 아니라 **불투명한 로컬 식별자**이고 이미 `~/.claude`·`~/.codex`에 평문으로 있다. 같은
  사용자 홈의 또 다른 로컬 파일(workspace 저장본)에 둘 뿐 권한 경계가 늘지 않으므로 redaction 대상이 아니다.
- 보존 `argv`는 redact한다. 토큰성 key(`TOKEN`·`SECRET`·`KEY`·`AUTH`·`PASSWORD`·`CREDENTIAL` 등 —
  [프로젝트 규칙](project-rules.md) "민감정보 redaction 기준" 단일 출처)를 가진 `--key=value` 토큰은 **드롭**
  (deny-by-default). `--dangerously-skip-permissions` 같은 무해 플래그만 보존한다.
- env는 여전히 통째로 저장하지 않는다 — session_id는 트랜스크립트 파일에서 얻으므로 자식 env를 덤프하지 않는다.

### config 토글

- `workspace.restore-claude` / `workspace.restore-codex` — 각각 독립, **기본 false(opt-in)**.
- 토글이 꺼지면 그 종류는 캡처·복원 양쪽 다 비활성(일반 셸로 복원).

## command 관련 용어

`shell_entry`:

- pane을 다시 열 때 시작할 기본 shell argv다.
- 예: `["zsh", "-l"]`.
- workspace restore의 기본 동작은 shell_entry 실행까지만이다.

`startup_recipe`:

- 사용자가 config로 명시한 재시작용 command다.
- 예: `["npm", "run", "dev"]`.
- 자동 실행 후보가 될 수 있지만 v1 기본값은 보수적이어야 하며, confirmation/allowlist 정책 없이 destructive할 수 있는 command를 자동 실행하지 않는다.

`last_observed_command`:

- shell integration이 관측한 마지막 command다.
- 최근 작업 세션 UI나 힌트에는 쓸 수 있지만 자동 재실행 대상은 아니다.
- 이 값을 저장할 경우에도 민감정보 redaction과 사용자 동의가 필요하다.
- 단, claude/codex는 위 "에이전트 세션 자동 resume" allowlist 예외로 별도 관리한다(임의 명령이 아니라 도구 자체 resume).

## 저장 모델 초안

```text
maru.workspace.v1
workspace id=<stable-id>
root /path/to/repo

surface 1
  title api-server
  cwd /path/to/repo
  shell-entry argv ["zsh", "-l"]
  startup-recipe none
  last-observed-command none
  env-override PATH=/usr/local/bin:/usr/bin:/bin

layout
  tab 1 surface=1
```

실제 직렬화는 나중에 정한다. 중요한 것은 저장 대상이 live object가 아니라 선언적 상태라는 점이다. 첫 줄 schema 토큰은 snapshot/trace와 같은 규칙으로 bare 토큰(`maru.workspace.v1`)을 쓰고 `schema=` 접두어를 두지 않는다.

## 사용자 지정 이름(custom_name)과 자동 제목

워크스페이스(사이드바 탭)·Pane(분할 영역)·Term(가로 탭)에는 두 종류의 라벨 출처가 있다.

- **자동 제목(auto title)**: 셸/프로그램이 정하는 값. Term은 OSC 0/2(window title)·OSC 7(cwd)에서 매 세션 라이브로 다시 도출된다. 워크스페이스·Pane은 자동 제목 출처가 없다(번호로 식별).
- **사용자 지정 이름(custom_name)**: 사용자가 직접 붙인(rename) 이름. 이것만이 사용자 의도라서 **영속해야 할 유일한 라벨 데이터**다.

표시 규칙(단일):

```text
표시 라벨 = custom_name(비어있지 않으면) → 없으면 auto title → 없으면 기본값("shell"/번호)
```

베이스/결정: "사용자 이름이 있으면 우선, 없으면 자동"은 iTerm2·Terminal.app의 탭 제목 동작을 베이스로 한다(사용자가 이름을 정하면 셸 OSC가 덮어쓰지 않고 고정). 자동 제목은 매 세션 라이브로 재도출되므로 사용자 의도가 아니며, **custom_name과 별도 필드**로 둔다 — 같은 칸에 섞으면 OSC가 들어오는 순간 사용자 이름이 사라진다.

저장 모델(앞 절 직렬화 모델에 필드 추가, 빈 문자열 = 이름 없음):

```text
tab ... custom-name="<workspace custom_name>" pinned=<0|1> background-color=<0xRRGGBB 10진> accent-color=<0xRRGGBB 10진>
                                                 # 워크스페이스 custom_name + 위치 고정(pinned) + 카드 배경 tint + 좌측 accent 막대색
pane ... custom-name="<pane custom_name>"        # pane custom_name (자동 출처 없음)
surface custom-name="<term custom_name>" title="<auto OSC title>" cwd=... ...
                                                 # surface는 custom_name(사용자)과 title(자동) 둘 다 저장
```

세 계층의 사용자 이름은 모두 `custom-name=` 키로 통일한다(Surface만 추가로 auto `title=`를 둔다). 워크스페이스(tab)는
우클릭 컨텍스트 메뉴로 정하는 **위치 고정(`pinned`)·카드 배경색(`background-color`)·좌측 막대색(`accent-color`)**도 사용자
의도라 영속한다(custom_name과 같은 자리; 배경색·막대색은 직교한 별도 값 — docs/tabs-splits-layout.md). 직렬화 파서는
positional이라 키 순서·개수가 writer와 정확히 맞아야 한다(필드 추가는 포맷 변경 — 아래 "하위 호환은 고려하지 않는다"·
"저장 파일을 통째로 파싱 못 할 때" 정책에 따라, 옛 저장 파일은 시작 시 조용히 기본 창으로 폴백하고 다음 정상 종료 때 self-heal).

- custom_name은 트리 내 위치(인덱스)로 round-trip한다(cwd/title과 같은 식별).
- 자동 제목(surface `title`)은 복원 직후 셸이 OSC를 다시 보내기 전까지의 폴백 표시용으로만 저장·소비한다. custom_name이 있으면 표시 규칙상 자동 제목보다 우선한다.
- 하위 호환은 고려하지 않는다 — 필드는 `maru.workspace.v1`에 직접 추가한다(구버전 파일 읽기 보장 없음). 이는 **현재** 동작이며,
  per-tab 스칼라 필드가 계속 늘어남에 따라 아래 "[직렬화 진화 계획](#직렬화-진화-계획-스칼라-필드-key-addressed-파싱-미구현)"으로 이 정책을 좁힐 예정이다(additive 스칼라만 하위호환).

## 직렬화 진화 계획: 스칼라 필드 key-addressed 파싱 (미구현)

> 상태: **미구현 계획**. 현재 파서는 여전히 strict positional + 통째 폴백/self-heal(위 정책). 이 절은 언제·왜·어떻게 전환할지의 단일 출처다.

**동기.** per-tab 스칼라 속성(현재 `custom_name`·`pinned`·`background_color`·`accent_color`; 앞으로 아이콘·정렬·메모 등 계속 추가 예정)이 늘 때마다,
현재 strict positional 파서는 그 키가 없는 옛 저장 파일을 **통째 파싱 실패**로 떨궈 **업데이트마다 워크스페이스 배치가 1회 리셋**된다
(다음 정상 종료의 self-heal 전까지). 필드 하나면 감수할 만하지만, 지속적으로 늘어나는 방향이라 누적 UX 비용이 커진다.

**목표.** 줄 안의 **스칼라 `key=value` 필드**를 **순서 무관·이름 조회 + 기본값**으로 읽어, additive 스칼라 필드 추가가 옛 파일을 안 깨게 한다(무손실
하위호환). 구조 골격(라인 타입 토큰·self-delimiting 카운트·tree preorder)은 그대로 둔다 — 스칼라가 아니라 구조라, 바뀌면 여전히 버전/self-heal 사건이다.

**핵심 결정 — required vs optional 분류(실패 모델 보존).** key-addressed는 "없는 키=기본값"이라, 손상 파일이 조용히 그럴듯한-틀린 상태로 파싱될
위험이 있다(현재 strict의 loud-fail이 주는 손상 탐지를 잃음). 이를 막으려 키를 둘로 나눈다:

- **required(구조 키)** — 없으면 블록 파싱 자체가 불가능한 키(`tabs=`·`panes=`·`surfaces=`·`agent-argc=` 등 뒤 블록 개수를 결정). 없으면
  `BadLine → 파일 통째 폴백`(현행 loud-fail 유지 = 손상 탐지 보존). 기본값으로 못 때운다.
- **optional(스칼라 속성)** — 합리적 기본값이 있는 키(`custom-name`=""·`pinned`=0·`background-color`=0·`accent-color`=0·`title`="" 및 앞으로의
  per-tab/surface 스칼라 전부). 없으면 기본값, 실패 없음.

**미지 키 정책.** 옛 바이너리가 새 파일의 모르는 스칼라 키를 만나면 **조용히 skip(artifact 로그 남김)** — 앞뒤 버전 호환. 오타 키도 조용히 무시되는
트레이드오프는 optional 속성이라 감수하고, 구조 이상은 위 required 규칙이 잡는다.

**범위 밖(이 계획이 해결하지 않는 것).** 새 블록 타입 추가·tree 인코딩 변경·카운트 의미 변경 = 구조 파괴 변경이라 여전히 스키마 버전 bump
(`maru.workspace.v1`→`.v2`) 또는 self-heal 폴백 대상이다("[저장 파일을 통째로 파싱 못 할 때](#저장-파일을-통째로-파싱-못-할-때)"). additive 스칼라 필드는 버전을 올리지 않는다.

**마이그레이션 경로(증분·저위험).**

1. 라인-tail 파서 도입: 타입 토큰 뒤 나머지 토큰을 (key,value)로 훑어 `getUint(key, default)`/`getQuoted(key, default)`/`getEnum(...)` +
   구조 키용 `requireUint(key)`를 제공(`FieldReader` 확장 또는 대체).
2. `parseTab`/`parsePane`/`parseSurface`를 positional read에서 key-addressed read로 전환(구조 키만 require).
3. writer 불변(이미 `key=value`를 씀) → round-trip 고정점 유지. reader만 바뀌어 옛 파일이 기본값으로 복원 → **이후 additive 업데이트의 리셋 UX 소멸**.
4. 이 문서의 "하위 호환"·"실패 처리" 문구 갱신: "additive 스칼라 = 하위호환(key-addressed+기본값), 구조/버전 변경 = 폴백+self-heal".
5. 테스트: 옛 포맷 fixture(새 키 없음)가 기본값으로 복원 / 구조 키 손상이 여전히 BadLine / 미지 키 skip / round-trip 고정점.

**트리거(언제).** 지금(색 필드 하나) 하지 않는다 — self-heal로 충분하고 YAGNI. **다음 per-tab 필드 묶음이 들어오기 직전에 별도 PR로** 전환해,
그 필드들이 처음부터 key-addressed reader 위에 안착하고 리셋을 유발하지 않게 한다. 전환 자체가 전략 수정이므로 [PR 체크리스트](pr-checklist.md)의 "전략 수정 규칙"에 따라 진행한다.

## env 저장 정책

환경변수는 민감정보가 많다.

저장하면 위험한 예:

```text
AWS_SECRET_ACCESS_KEY
GITHUB_TOKEN
NPM_TOKEN
DATABASE_URL
COOKIE
PASSWORD
PRIVATE_KEY
```

초기 정책:

- 현재 process의 전체 env를 자동 저장하지 않는다.
- 사용자가 명시한 env override만 저장한다.
- redaction 키 목록과 allowlist 기준은 [프로젝트 규칙](project-rules.md)의 "민감정보 redaction 기준 (단일 출처)"을 따른다. 이 문서에 키 목록을 따로 복제하지 않는다.

## command 저장 정책

명령은 shell string보다 argv 배열이 안전하다. 이 절에서 말하는 명령은 `startup_recipe`다. `last_observed_command`는 자동 재실행 대상이 아니므로 이 저장 정책에 섞지 않는다.

권장:

```text
argv ["npm", "run", "dev"]
```

주의:

```text
shell "npm run dev && deploy"
```

shell string은 quoting, expansion, injection 문제가 있다. 초기에는 startup_recipe를 `argv` 형태로 제한한다. shell string 지원이 필요하면 별도 UX와 경고가 필요하다.

## 실패 처리

restore가 실패해도 workspace 전체를 버리지 않는다.

예:

- cwd가 사라짐
- command executable이 없음
- env override가 redaction 정책에 걸림
- surface 하나만 복구 실패

이 경우 실패한 surface와 이유를 artifact에 남기고, 가능한 나머지 surface는 복구한다.

### 저장 파일을 통째로 파싱 못 할 때

헤더 불일치·직렬화 포맷 변경(하위호환 미고려)·손상으로 저장 파일을 **통째로** 파싱 못 하면, **알림(notice) 없이 조용히 기본 단일 창으로 시작**한다. 복원 불가는 사용자 잘못이 아니고, 특히 포맷이 바뀌면 이전 버전 저장 파일이 모두 여기로 떨어지는데 이를 "손상" 모달로 알리면 업데이트 후 첫 실행마다 키를 막는 중앙 팝업이 떠 UX가 나쁘다. 저장본은 다음 정상 종료 때 새 포맷으로 덮어써져 자연히 해소된다(self-heal). 빈 workspace(저장 없음)와 같은 조용한 기본 창 동작이다. 일부만 복원 실패(파싱은 됐으나 일부 창 적용 실패)는 이와 별개로 안내할 수 있다.

## 초기 테스트

- workspace fixture round-trip.
- live PTY handle이 저장 모델에 들어가지 않는지 테스트.
- 민감 env key가 저장되면 실패하는 테스트.
- `shell_entry`와 `startup_recipe argv`가 round-trip되는 테스트.
- `last_observed_command`가 자동 실행 후보로 저장되지 않는 테스트.
- cwd가 없을 때 surface별 restore failure artifact를 남기는 테스트.
- claude/codex `agent_kind`·`session_id`·보존 `argv`가 round-trip되는 테스트.
- 토큰성 key(`--api-key=…` 등)를 가진 argv 토큰이 redact(드롭)되는 테스트.
- `session_id`를 못 찾을 때 `--continue`/`resume --last` 폴백으로 degrade하는 테스트.
