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

저장하지 않는 것:
  live PTY handle
  child process id
  임의의 전체 env dump
  last_observed_command 자동 재실행 정보
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

## 초기 테스트

- workspace fixture round-trip.
- live PTY handle이 저장 모델에 들어가지 않는지 테스트.
- 민감 env key가 저장되면 실패하는 테스트.
- `shell_entry`와 `startup_recipe argv`가 round-trip되는 테스트.
- `last_observed_command`가 자동 실행 후보로 저장되지 않는 테스트.
- cwd가 없을 때 surface별 restore failure artifact를 남기는 테스트.
