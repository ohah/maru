# Session host 실행 중 업그레이드

이 문서는 앱 업데이트 뒤에도 이미 살아 있는 terminal runtime의 PTY·자식 프로세스·`TerminalCore`를 유지한 채
`maru-sessiond` binary를 교체하는 계약의 단일 출처다. 일반 attach·runtime 소유권은
[영속 터미널 세션 호스트](persistent-session-host.md), workspace의 `runtime-handle` 저장은
[Workspace Restore](workspace-restore.md), 화면 전송 codec은 `maru.screen-stream` 계약을 따른다.

> **상태: U0 inventory, U1 codec, U2 quiesce 핵심, U3 exec/rollback fixture, U4 typed adapter 기반과
> U5 제품 daemon controller·preflight·pathname exec·target/rollback restore activation을 연결했다.
> caller가 frozen N-1/current라고 증명한 signed executable의 non-empty PTY 성공 경로를 실행할 opt-in E2E
> 하네스는 구현했지만, 저장소에는
> 서명된 두 release artifact가 없어 아직 통과 증거를 만들지 못했다. 최대치 근처 multi-runtime 제품 restore,
> non-empty PTY rollback activation, 전 구간 failure injection, 업그레이드 결과 notice와 soak gate도 열려 있으므로
> U5 완료는 주장하지 않는다.**
> **앱 재실행 orchestration은 연결됐다** — GUI는 시작할 때 같은 build의 host가 없으면, build_id만 다른 살아 있는
> host를 찾아 자동으로 exec 교체를 시도한다(`host_connect.tryUpgradeExistingHost`). 이 시도는 **best-effort**다:
> 후보가 없거나 capability 미광고·prepare 거부·재연결 실패면 조용히 기존 spawn 경로로 떨어져 새 host를 띄운다.
> 업그레이드 실패가 곧 "터미널을 못 여는 실패"가 되어서는 안 되기 때문이다.
> **재연결 성공만으로 채택하지 않는다** — host가 accepted를 보내고도 exec에 실패해 rollback하면 같은 `host_id`로
> 재연결은 성공하지만 이미지는 옛것 그대로다. 그 연결을 채택하면 GUI가 host-backed로 믿고 `runtime.spawn`을 걸었다가
> 옛 host가 모르는 capability(`runtime_core_command_v1`)로 실패해 모든 터미널이 in-process로 떨어진다 —
> `build_id` 게이팅이 막아 주던 상황을 업그레이드 경로가 우회해 만드는 셈이다. 그래서 재연결 뒤 hello ack의
> `build_id`가 target과 정확히 같을 때만 채택하고, 다르거나 광고하지 않으면(fail-closed) 연결을 버려 spawn으로 간다.
> 현재 살아 있는 host가 `host_exec_upgrade_v1`을 광고하지 않으면 새 앱은 그 host를 실행 중 교체할 수 없다.
> 이 경우 지원하는 N-1 MRSH adapter로 attach해 기존 runtime을 그대로 쓰거나, attachment가 모두 끝난 뒤 구 host를
> 계속 drain한다. **attachment가 0이어도 runtime이 하나라도 살아 있으면 구 host를 종료하지 않으며, runtime count가
> 0이 된 뒤에만** 자연 종료하고 새 host를 시작한다. capability 없는 host를 죽여 migration처럼 보이게 하지 않는다.
> 자연 종료는 세 조건(runtime을 한 번이라도 서빙했음 · 지금 runtime 0 · 붙은 client 0)을 모두 만족한 채 유예가
> 지나야 성립한다(`daemon.shouldExitNaturally`). 신생 host가 첫 spawn 전에 스스로 물러나면 그 host를 띄운 GUI가
> endpoint를 잃기 때문이다.
>
> **fd 상한 제약**: exec layout은 fd 40부터 `exec_fd_set.max_slots`(= `max_runtime_count` + 3 = 259)개의 **연속 빈
> 슬롯**을 요구한다(`findAvailableLayout`). launchd가 GUI에 주는 기본 soft limit은 256이고 host가 그대로 상속하므로,
> Dock·Finder로 켠 앱이 띄운 host에서는 `40 + 259 > 256`이라 탐색이 **항상** 실패하고 `handoff_failed`로 끝난다
> (`finishPreclosedWithoutLayout`). 그래서 host는 시작 시 soft limit을 올린다(`daemon.raiseFileDescriptorLimit`,
> best-effort). 이 제약을 모르면 "업그레이드가 한 번도 성공하지 않는" 현상의 원인을 찾을 수 없다 — 실제로 모든
> host manifest의 `upgrade_epoch`가 0이었고 빌드를 바꿀 때마다 옛 host가 고아로 쌓였다.

## 1. 결론

첫 제품 범위는 **attachment가 0인 upgrade-capable host의 같은 PID `exec` 교체**다.

- host PID, `host_id`, 모든 `runtime_id`, PTY master fd, terminal child pid/process group을 유지한다.
- `exec` 전 logical runtime state를 별도 handoff codec으로 저장하고 새 binary가 전량 검증한 뒤 runtime을 재구성한다.
- workspace의 `host_id:runtime_id` binding은 바뀌지 않으며 migration 임시 상태를 workspace 파일에 저장하지 않는다.
- 새 GUI는 N-1 MRSH adapter로 구 host에 연결해 업그레이드를 요청한다. 현재 major header로 구 major host에
  직접 hello를 보내는 방식은 사용하지 않는다.
- 다른 Maru process/window, 외부 `maru attach`, SSH attach가 하나라도 붙어 있으면 강행하지 않고
  `upgrade_busy`로 미룬다. 구 host adapter attach는 계속 가능하다.
- 기존 `maru.snapshot.v3`와 `maru.screen-stream`은 handoff에 사용하지 않는다. 둘은 각각 디버그/복원용 부분
  snapshot과 resolved 화면 투영이라 parser·queue·PTY 소유권을 보존하지 못한다.

별도 PID로 PTY fd만 넘기는 방식은 v1에서 쓰지 않는다. fd 전달만으로는 terminal child의 parent와 `waitpid` 회수권이
새 host로 이동하지 않기 때문이다. 같은 PID `exec`는 child-parent 관계를 유지하므로 현재 소유 모델에서 가장 작은
정확한 경계다.

## 2. 지원 범위

### 목표

- 앱 업데이트를 위해 GUI가 정상 종료된 뒤, 살아 있는 host의 모든 runtime을 새 binary로 옮긴다.
- partial UTF-8/CSI/OSC/DCS/APC, active/alternate screen, scrollback, selection, link/grapheme/image storage,
  cwd/title/semantic/input mode, pending notification 같은 logical state를 보존한다.
- 아직 읽지 않은 PTY output은 kernel PTY buffer에 남기고, 이미 읽은 bytes는 정확히 한 번만 core에 반영한다.
- host에 admission된 input/core command/PTY response를 잃거나 두 번 쓰지 않는다.
- target rollback handler가 설치됐고 검증된 backup/self-image closure가 온전한 controlled restore 실패는 PTY를
  건드리기 전에 구 binary로 rollback한다. loader/entrypoint 이전 crash와 primary+backup 동시 손상은 비목표다.
- runtime 종료 뒤 child exit status를 정확히 한 번 회수한다.

### 비목표

- `host_exec_upgrade_v1`이 없는, 이미 실행 중인 legacy host를 사후에 live-upgrade 가능하게 만드는 것.
- attachment가 남아 있는 동안의 무중단 collaborative upgrade. v1은 observer/controller 모두 0이어야 한다.
- host crash, SIGKILL, 전원 종료, kernel failure 뒤 runtime 복구. 이는 persistent-session host 전체의 비목표다.
- 서로 다른 PID 사이 child-parent 관계 자체를 이전하는 것.
- 앱 binary downgrade를 일반 제품 기능으로 제공하는 것. rollback은 한 upgrade attempt의 pre-commit 복구에 한정한다.
- WKWebView, file editor buffer, GUI layout을 handoff state에 넣는 것.

## 3. 호환 전략

호환은 세 층을 분리한다.

1. **MRSH adapter**
   - 새 앱은 current와 N-1 major의 hello/header/screen codec adapter를 함께 제공한다.
   - adapter는 구 host와 통신하고 `host_exec_upgrade_v1` 유무를 확인한다.
   - adapter만으로도 구 host runtime에 attach할 수 있다. 이것은 migration이 아니라 호환 접속이다.
2. **upgrade command**
   - capability가 있으면 구 host 자신의 protocol adapter로 `host.upgrade.prepare`를 요청한다.
   - request에는 새 executable의 검증된 절대경로, target build identity, handoff reader 범위를 싣는다.
   - capability가 없거나 target이 writer schema를 읽지 못하면 업그레이드하지 않는다.
3. **handoff codec**
   - MRSH와 독립된 `maru.host-handoff.v1` envelope를 쓴다.
   - writer schema, minimum reader, runtime count, section length, checksum, required/optional field tag를 가진다.
   - 새 binary는 current와 N-1 handoff schema reader 및 명시적 up-converter를 제공한다.
   - 모르는 required field, 중복 field, cap 초과, checksum 불일치는 restore 전에 fail-close한다.

`upgrade_attempt_record` schema v1·v2는 capability를 제품에서 한 번도 광고하지 않은 개발 중 component format이며
호환 release baseline이 아니다. Rollback image authority와 exec 전후 단일 absolute monotonic deadline을 포함한
schema v3를 **최초 제품 baseline**으로 고정한다. 향후 capability를 실제 배포한 뒤의 v4부터는 위 N-1
reader/up-converter 규칙을 적용한다. v1·v2 record는 rollback executable 또는 남은 deadline을 안전하게 복원할
정보가 없으므로 추측 변환하지 않고 거부한다.

### 관측 metadata에 스칼라를 더할 때 — major를 올리지 않는다

`runtime.metadata`의 metadata object는 **모르는 스칼라 키를 흘려보낸다**(`drainUnknownScalar`). 그래서 필드를
더하는 쪽은 major를 올리지 않고, 대신 **양방향 결손을 값으로 흡수**한다:

- **신 앱 ↔ 구 host**: 키가 없으니 파서 기본값(0)이 남는다. 소비자는 0을 "모른다"로 다뤄야 하고, 그 자리를
  필수(`_seen`) 키로 만들면 안 된다 — 필수로 만들면 구 host의 관측 전체가 `Malformed`가 되어 **터미널이 아예
  안 뜬다**(리소스 숫자 하나 때문에 세션을 잃는 교환이다).
- **구 앱 ↔ 신 host**: 모르는 키라 조용히 버려진다. 기존 동작 그대로다.

2026-08-27에 `child_pid`·`host_pid`가 이 규칙으로 들어왔다(상태바 리소스 항목이 host-backed 터미널과 데몬
자신을 재는 두 뿌리 — [status-bar.md](status-bar.md) §4.1). **0은 "없다"와 "모른다"를 가를 필요가 없다** — pid 0은
어차피 유효한 측정 대상이 아니라, `foreground_pgid`처럼 present 플래그를 따로 두지 않았다.

MRSH major를 올리는 PR은 다음을 모두 만족해야 한다.

- 직전 release major adapter가 실제 frozen-old-binary fixture와 통신한다.
- 직전 handoff schema를 current in-memory state로 변환한다.
- 구 writer가 새 reader 범위에 포함되는지 upgrade 전 협상한다.
- adapter와 converter 제거 시점은 해당 release의 N-1 지원 종료 정책과 함께 문서화한다.

### `host.upgrade.*` command

N-1 adapter가 구 wire로 보내는 prepare request는 다음 logical schema를 쓴다.

```text
host.upgrade.prepare {
  attempt_id: 32-lower-hex,
  target_path: absolute UTF-8 path,
  target_build_id: non-empty string,
  target_sha256: 64-lower-hex,
  handoff_reader_min: u16,
  handoff_reader_max: u16
}
```

`attempt_id`는 client가 생성하는 opaque 128-bit idempotency key이며 순서 의미가 없다. host의 성공한 교체 횟수는
별도 monotonic `upgrade_epoch`가 소유한다.

host는 **요청 source path**를 처음 staging 뒤 다시 실행 권위로 사용하지 않는다. no-follow로 연 fd의 type/UID를
확인하고 owner-only attempt directory에 `O_EXCL`로 복사·sync·rename·directory sync한 **staged target inode**의
hash/build identity를 검증한다. staged image는 현재 release executable과 모두 strict codesign 검증을 통과하고
Apple certificate/team을 포함한 designated requirement가 exact match해야 한다. exec 직전 staged inode/path
identity를 다시 확인한다. macOS 공개 API에는 `fexecve`/`execveat`가 없으므로 실제 `exec`는 staged pathname을
사용한다. 따라서 같은 UID의 다른 process는 v1 local trust boundary 안에 두며, path 교체가 주입되면 target entry가
recorded hash/dev/inode 불일치로 commit하지 않고 rollback한다. 이를 “FD가 실행 image 자체를 고정한다”고 표현하지 않는다.

성공 응답은 `{attempt_id,state:"accepted"}`이고 반드시 `reply_and_close`로 client에 전량 쓴 뒤 request fd를 닫는다.
실제 quiesce/exec는 connection handler가 아니라 daemon-owned pending attempt가 fd close를 관측한 뒤 시작한다.
같은 `attempt_id`와 같은 target identity 재요청은 같은 결과를 돌려주며, 같은 ID의 다른 target은
`attempt_conflict`다. accepted는 upgrade 성공을 뜻하지 않는다.

완료 attempt replay는 새 실행 예약이 아니라 read-only 결과 조회이므로 all-or-none preflight보다 먼저 분류한다.
단, 이 우회는 `attempt_id`만 보지 않는다. owner가 보존한 요청 source path, target build ID, SHA-256,
`handoff_reader_min`, `handoff_reader_max`가 모두 같은 경우에만 completed report를 돌려준다. 같은 ID에서 이
immutable identity 중 하나라도 다르면 preflight·target staging을 건드리지 않고 `attempt_conflict`다. active
attempt도 같은 ID·identity의 write retry만 기존 all-or-none preflight를 다시 통과하며, active attempt와 충돌하는
다른 ID/identity는 read-only probe에서 `attempt_conflict`다. 알려지지 않은 신규 요청은 기존 preflight를 통과한다.

`host.upgrade.status {attempt_id}`는 `pending | resumed | rolled_back | committed | failed_nonretryable`와 typed reason을
돌려준다. client의 성공 판정은 EOF가 아니라 재접속한 `host.info`의 **같은 `host_id`**, target build/protocol,
증가한 `upgrade_epoch`, exact runtime ID 집합이다. `resumed`/`rolled_back`은 원 target으로 자동 재시도하지 않으며
명시적 새 attempt ID가 필요하다. accepted 뒤 attachment/runtime graph가 바뀌어 quiesce를 취소한 경우는
`resumed/runtime_changed`로 기록하며 deadline 실패로 위장하지 않는다.

## 4. 권위와 저장 위치

- 실행 중 권위는 계속 host memory의 `TerminalRuntimeRegistry`와 각 runtime의 `TerminalCore`·`LivePtySession`이다.
- workspace manifest는 `host_id:runtime_id` binding만 가진다. handoff bytes나 PTY fd 번호를 저장하지 않는다.
- handoff는 session-host owner-only runtime directory 아래 attempt별 임시 파일에 쓴다. `0600`, regular file,
  same-UID, no-follow를 검증하고 write→sync→atomic rename 뒤에만 committed로 본다.
- staged rollback executable은 **upgrade 요청 때가 아니라 upgrade-capable host 시작 시점**에 daemon이 다시 검사한
  running-image identity와 pathname 내용을 대조한 뒤 owner-only host
  directory에 고정하고 hash/build identity를 기록한다. 앱 updater가 bundle의 원 executable을 이미 교체한 뒤에는
  실행 중 memory image만으로 동일한 구 binary를 안전하게 복원할 수 없기 때문이다. 이 self-image staging에
  실패한 host는 `host_exec_upgrade_v1`을 광고하지 않는다.
- attempt 시작 때 staged self-image의 same-UID regular-file/no-follow/hash를 다시 검증한다. staging과 검증이
  끝나지 않으면 quiesce를 시작하지 않는다.
- old writer는 handoff를 쓴 뒤 **자기 reader로 전량 read-back/checksum/semantic validation**한다. 독립된 rollback
  backup도 만들고 같은 검증을 통과시킨다. staged target의 `upgrade-preflight` process가 primary handoff를 실제
  current reader로 decode/up-convert하는 것까지 성공해야 destructive exec를 시작한다.
- `upgrade-preflight` helper의 fd allowlist는 `/dev/null` 0/1/2와 read-only primary handoff slot 하나뿐이다.
  PTY master, owner lease, rollback backup, host listener/client fd를 helper에 넘기지 않았음을 open-fd probe로 단언한다.
- 검증된 primary와 rollback backup을 read-only fd로 다시 연 뒤 경로는 **exec 전에 unlink**한다. target은 primary,
  staged-old rollback은 backup fd를 읽는다. crash면 kernel close가 secret-bearing inode 둘을 회수한다. argv/env에는
  fd slot과 attempt ID만 싣고 terminal bytes/cwd는 싣지 않는다. disk preflight는 logical handoff cap의 2배와
  staged binaries를 포함한다.
- attempt record는 `host_id`, opaque `attempt_id`, writer/next epoch, exec 전후 공유하는 absolute monotonic deadline,
  exact sorted runtime ID 집합, staged target path/build/hash/dev/inode/size/reader 범위, completed idempotency ledger와
  immutable `rollback_budget=1`을 가진다.
  primary/backup은 같은 bytes이며 소비 횟수를 서로 다르게 저장하지 않는다. target entry는 exact attempt argv와
  primary role, rollback entry는 같은 attempt argv와 backup role을 함께 검증해 restore token을 발급한다. rollback
  token으로 복원한 attempt는 다시 rollback할 수 없고 `rolled_back` 외 terminal report를 기록할 수 없다. 이 token의
  실제 FD provenance는 제품 bootstrap이 inherited allowlist의 고정 slot→copy mapping을 검증한 같은 함수 안에서
  decode·발급하고 제품 restore activation이 그 typed token만 소비한다.
- target/rollback entry는 inherited target fd를 받지 않는다. exact inherited allowlist를 검증한 뒤 owner-only
  staged pathname을 `O_RDONLY|O_CLOEXEC|O_NOFOLLOW`로 다시 열고 record의 dev/inode/size/hash와 대조해 cleanup pin을
  재구축한다. 이 pin은 exec allowlist 바깥이며 이후 pathname 교체를 commit 전에 다시 거부하는 용도다.
- 성공 commit 뒤 staged target을 **새 current rollback self-image로 atomic promote**하고 directory sync한다.
  그 성공 뒤에만 이전 self-image를 삭제한다. promotion 실패면 새 host는 계속 serve하지만
  `host_exec_upgrade_v1` 광고를 즉시 내리고 owner에 permanent new-attempt latch를 걸어 이미 연결되어 ops를 복사한
  client도 다음 live upgrade를 시작하지 못하게 한다. 이미 끝난 attempt의 exact idempotent replay와 terminal
  status를 읽는 status-only ops는 유지한다. rollback self-image는 host lifetime 동안 유지하고 정상 host 종료 때
  삭제한다. 다음 host 시작은 새 process가 exact host owner lock을 얻은 뒤, capability를 광고하거나 target을
  staging하기 전에 owner-only host directory의 stale attempt와 staged target 잔해를 정리한다. sweep 대상 이름은
  `attempt-<32 lowercase hex>` directory와 `target-<32 lowercase hex>.image` regular file뿐이다. attempt directory는
  no-follow로 연 뒤 owner UID·0700과 parent에서 관측한 dev/inode가 일치하고, 내부가 owner UID의 regular
  `primary|backup` leaf 최대 두 개뿐일 때만 각 leaf를 pinned fd의 dev/inode와 다시 대조해 unlink한다. staged target도
  owner UID regular file, link count 1, parent에서 연 pinned fd와 같은 dev/inode일 때만 unlink한다. symlink, hard link,
  이름은 맞지만 종류·소유자·mode가 다른 entry, unknown child, 중복/초과 child, identity drift는 건드리지 않고 startup을
  fail-close한다. 각 unlink와 attempt `rmdir` 뒤 host directory를 fsync하며, 하나라도 실패하면 upgrade capability를
  광고하지 않고 새 attempt를 받지 않는다. `rollback-current`, `rollback-previous`, manifest, owner lock과 이름이 다른
  사용자 파일은 sweep 대상이 아니다. pathname 교체를 막기 위해 canonical entry는 동일 directory의
  `.sweep-attempt-<id>` / `.sweep-target-<id>.image` tomb로 no-replace rename한 뒤 pinned identity를 다시 확인하고
  제거한다. attempt 내부 `primary|backup`도 `.sweep-primary|.sweep-backup`을 거친다. sweep 도중 process가 죽으면 다음
  시작은 이 exact tomb 이름도 같은 원래 종류·identity 규칙으로 검증해 이어서 정리한다. canonical과 같은 ID의 tomb가
  동시에 있거나 tomb vocabulary가 어긋나면 어느 쪽도 추측해 지우지 않는다.

fd 번호는 durable identity가 아니다. handoff manifest의 runtime record가 inherited fd slot을 가리키고, 새 process가
실제 open fd의 type/flags를 다시 검증한 뒤 새 `PtySession`에 결합한다.

## 5. 상태 머신

```text
serving
  -> target_staging_preflight
  -> admission_closed
  -> quiescing
  -> handoff_committed
  -> handoff_reader_preflight
  -> restoring_manifest_published
  -> fd_slots_prepared
  -> exec_pending
  -> restore_validated
  -> restore_prepared
  -> committed
  -> serving
```

실패 전이는 다음처럼 고정한다.

| 실패 지점 | 결과 |
| --- | --- |
| target staging preflight | 아무 상태도 바꾸지 않고 구 host가 계속 serve |
| handoff reader preflight | 이미 unlink된 primary/backup의 열린 fd를 닫고 old reader/admission을 재개하며 exec하지 않음 |
| admission close 전 | 구 host가 계속 serve |
| quiesce/flush deadline | reader·admission을 재개하고 임시 파일 제거 |
| handoff write/sync/rename | CLOEXEC를 건드리지 않고 구 host 재개 |
| `exec` syscall 실패 | inherited flag를 원복하고 구 host 재개 |
| target entrypoint가 rollback handler를 설치한 뒤 pre-commit target-only invariant/OOM 실패 | PTY read/write/thread 시작 없이 검증된 backup fd로 staged 구 binary exec rollback |
| restore commit 뒤 host failure | host crash와 동일하며 v1 복구 범위 밖 |

한 attempt에는 opaque idempotency key와 최대 rollback 횟수 1을 둔다. restore argv의 target/rollback role과
attempt record의 immutable budget이 rollback binary의 재귀 target 실행을 막고, 최종 원인은 attempt terminal ledger의
`rolled_back/restore_failed`로 기록한다.

`exec` syscall 성공이 loader/dyld/entrypoint 도달을 보장하지는 않는다. target load/signature/초기화 중 crash처럼
rollback handler가 설치되기 전의 실패는 staged binary만으로 되돌릴 실행 주체가 없으므로 host crash 비목표다.
quiesce 전 target binary를 별도 `upgrade-preflight` process로 실제 load/entrypoint 실행해 이 위험을 줄이지만,
“모든 post-exec crash rollback”을 보장하지 않는다. staged self-image가 비-system dylib/framework에 의존하면 그
runtime closure까지 고정·검증할 수 있을 때만 capability를 광고한다.

primary handoff의 corrupt/truncated/checksum failure는 destructive exec **전** old-reader read-back과 target preflight가
잡아 구 host가 그대로 재개해야 한다. exec 뒤 primary가 새로 손상됐지만 backup은 온전한 controlled failure만 staged-old
rollback 대상이다. primary와 backup이 모두 손상되거나 rollback handler가 실행되지 못하는 crash는 복구 보장이 아니라
host crash 비목표다.

## 6. Preflight와 attachment 규칙

업그레이드는 아래가 전부 참일 때만 시작한다.

- 모든 runtime의 controller와 observer가 0이다.
- upgrade request connection 외 다른 active connection이 없다.
- spawn/terminate/resize/attach 및 controller takeover/release request가 처리 중이지 않다.
- notification response admission 전의 peek token과 controller transition owner turn이 남아 있지 않다. notification
  generation은 모든 client/control queue가 0인 upgrade gate 뒤 reconstructed=0이며, old token은 exec를 건너지 않는다.
- target executable이 same-UID regular file이고 허용된 Maru build identity를 가진다.
- host 시작 때 보존한 staged rollback self-image가 존재하고 recorded hash와 일치한다.
- target reader가 writer handoff schema와 runtime field set을 지원한다.
- handoff·rollback staging에 필요한 bounded disk space와 fd budget이 확보됐다.
- host 전체가 한 번에 옮겨진다. runtime 일부만 성공시키는 mixed-version host는 만들지 않는다.

GUI 재실행이 업그레이드를 유발할 때는 runtime attach보다 upgrade preflight를 먼저 한다. `upgrade_busy`면 current/N-1
adapter로 정상 attach하고, 마지막 attachment가 떨어진 뒤 다시 시도한다. 사용자 입력을 끊어서 업그레이드를 강행하지 않는다.

P5의 multi-fd reactor가 들어간 뒤 `active connection`은 accept-loop의 지역 변수가 아니라 모든
`ConnectionSlot`의 전역 상태다. `prepare accepted`의 linearization point에서 global frame admission을 닫고,
그 전에 dispatch된 non-upgrade operation이 0인지 확인한다. accepted reply를 완전히 flush한 뒤 upgrade request
slot 자체를 close/remove하고, queued mutation이 없는 unattached idle slot만 bounded close한다. partial request나
queued reply가 있으면 idle로 간주하지 않고 `upgrade_busy`로 취소한다. controller transition은 owner turn 밖에
prepared token을 보관하지 않고 AdmissionGate lease와 slot `in_flight_dispatch` 안에서 old revocation/new response
control batch admission과 registry commit까지 끝낸다. 이 batch는 requester response가 필수이고 기존 controller가 있을
때만 old revocation이 추가되는 최대 2-frame이다. 그러므로 queued revocation/response는 canonical pending/control ledger에
남고 attachment와 함께 drain을 막는다. 마지막에 controller/observer, subscription, pending control, slot,
in-flight dispatch가 모두 0인지 다시 확인한 뒤에만 아래 quiesce로 넘긴다.

accepted reply를 flush한 뒤 canonical client teardown이 final authority 0을 만들지 못하면 잔여 상태를 무시하고
exec하지 않는다. subscription, runtime attachment, admin lease, active slot/client/producer가 남은 경우는 소유권
원인을 증명할 수 없으므로 process fail-stop이다. 모든 connection authority는 0이고 빈 reactor의 aggregate budget
counter만 남은 경우에 한해 slot table과 `ConnectionKey` allocator generation은 보존하고 aggregate budget만 empty
값으로 canonical repair할 수 있다. key allocator를 재생성해 stale key가 새 slot과 ABA alias하게 만들지 않는다.
repair와 closed-and-drained gate 검증이 성공하면 armed attempt를 `resumed/handoff_failed`로 terminal 기록하고
strict preclosed admission gate를 다시 열어
기존 PTY/runtime serving을 계속한다. terminal 기록 또는 gate reopen을 확정하지 못하면 역시 fail-stop이다. 이 경계는
Debug assert나 ReleaseFast no-op에 의존하지 않고 두 최적화 모드에서 같은 typed 결과를 낸다.

## 7. Quiesce 계약

현재 reader의 stack-local response buffer와 실행 중 queue operation은 그대로는 직렬화할 수 없다. U2에서 reader의
in-flight 상태를 명시적 owned transfer state로 옮긴 뒤 다음 barrier를 구현한다.

1. global frame admission을 닫고 in-flight non-upgrade dispatch 0을 확인한다.
2. accepted reply를 flush하고 request slot을 close/remove한 뒤 unattached idle slot을 bounded close한다.
3. attachment, active slot, in-flight dispatch가 모두 0인지 다시 확인한다.
4. 이미 admission된 input bytes와 core command를 fence 순서대로 PTY에 전량 쓴다.
5. core가 만든 PTY response도 전량 쓴다. deadline 안에 flush되지 않으면 upgrade를 취소한다.
6. reader는 한 poll iteration 경계에서 멈춘다. local read buffer에 처리되지 않은 bytes가 없어야 한다. 현재
   `stopAndJoin`은 child를 종료하므로 사용할 수 없고, U2가 child/fd/queue를 닫지 않는 별도 pause→safe-point→join
   primitive를 먼저 추가한다.
7. 모든 `PtySession`의 `exited/closing/reaping=false`와 event queue empty를 다시 확인한다. quiesce 중 EOF/exit/error가
   생겨 reader가 terminal event를 만들었으면 status를 버리거나 serialize하지 않고 upgrade를 취소해 구 host의 정상
   termination path가 정확히 한 번 소비하게 한다.
8. core lock을 얻어 logical state를 encode한다.
9. PTY kernel buffer에 아직 읽지 않은 output은 그대로 둔다.

admission close부터 old-reader read-back, 두 handoff sync, target preflight, exec 직전까지의 **전체 pause
cooperative deadline budget은 5,000ms**다. 어느 하위 단계든 남은 예산 안에 끝나지 않으면 exec하지 않고
reader/admission을 재개한다.
handoff store API는 absolute deadline을 필수로 받고 decode 전후, 두 copy의 preallocation/write/fsync/read-back,
최종 directory sync 뒤까지 expiry를 검사한다. 다만 blocking `F_PREALLOCATE`/`fsync` syscall 자체를 선점하지는
못하므로 제품 coordinator는 quiesce 전에 I/O budget을 보수적으로 admission해야 한다. 이 예산을 넘는 큰 runtime
state는 8 GiB codec hard cap 안이더라도 live upgrade 대상이 아니며 side-by-side drain을 쓴다.

U5 제품 admission은 accepted reply를 flush하고 reader를 멈추기 **전** 다음 증거를 한 번에 만든다.

1. 현재 live graph를 core lock 아래 read-only로 encode해 attempt record와 notification section까지 포함한 exact
   preview byte 수를 구한다. preview는 PTY fd를 adopt하거나 reader/admission 상태를 바꾸지 않는다.
2. preview가 64 MiB operational cap 안인지 확인하고, owner-only attempt directory에 그 길이의 primary/backup 두
   파일을 `O_EXCL|O_NOFOLLOW`, `0600`, `F_PREALLOCATE`로 전량 예약한다. `statfs`의 가용량 추정만으로 통과시키지
   않는다. 예약 실패는 `state_too_large`로 old graph를 그대로 serve한다.
3. 같은 owner directory에서 bounded, incompressible sample을 write+sync+read-back한 durable probe를 quiesce 전에
   수행한다. elapsed가 probe 자체 deadline을 넘거나, 측정된 처리율에 보수적 safety factor를 적용해도 preview 두
   copy가 남은 5,000ms budget 안에 끝나지 않으면 live migration을 거부한다. 최근 같은 filesystem에서 성공한
   handoff 처리율은 더 느린 값일 때만 추가 상한으로 쓸 수 있으며, 임의의 낙관적 기본 처리율은 두지 않는다.
   probe pathname/fd도 attempt reservation owner가 exact-once 정리한다.
4. quiesce 뒤 authoritative encode 결과는 preview보다 클 수 있다. 이미 예약한 길이를 넘거나 preview가 묶은
   host/runtime membership이 달라졌으면 예약을 폐기하고 reader/admission을 재개한다. reader가 계속 처리하는 동안
   화면·notification의 logical generation이 전진하는 것은 정상이며, 최종 bytes가 예약 안에 있으면 commit할 수
   있다. 최종 bytes 자체의 codec·checksum·read-back 검증은 생략하지 않는다.

예약 owner는 attempt 하나이며 성공 commit, 모든 in-process retryable rollback과 deadline 경로에서 primary/backup
pathname과 fd를 exact-once 정리한다. 정리가 실패하면 정상 재개로 축소하지 않고 invariant violation으로 fail-stop한다.
`SIGKILL`·전원 손실은 userspace cleanup을 실행할 수 없으므로 다음 exact host owner가 시작할 때 위 owner-only stale
attempt sweep을 실행한다. sweep이 residue를 신뢰할 수 없으면 keep-alive service는 계속 열되 upgrade capability와 새
attempt admission만 닫는다.
이 pre-admission은 기존 `handoff_store.commit`의 길이·identity·deadline 검증을 대체하지 않고 그 앞에 추가된다.

이 순서에서 upgrade snapshot 시점은 “모든 admitted outbound가 PTY에 적용됐고, 마지막 read chunk가 core에 적용된 직후”다.
새 binary는 같은 fd에서 다음 unread byte부터 시작한다. 화면 generation은 보존하고 restore 뒤 첫 client에는 full snapshot을
보내므로 client delta base는 이전 connection에서 이어 쓰지 않는다.

## 8. Handoff state

### hard cap

모든 길이의 add/multiply와 file offset은 allocation/read 전에 checked arithmetic으로 검증한다. cap 초과는 일부
runtime을 adopt하지 않고 전체 attempt를 `state_too_large`로 취소해 side-by-side drain으로 돌아간다.

| 항목 | 상한 |
| --- | ---: |
| runtime count | 256 |
| total handoff bytes | 8 GiB |
| live durable two-copy commit | 64 MiB |
| runtime section | 1 GiB |
| 단일 TLV/blob | 512 MiB |
| grid `cols × rows` / decoded cell count | 16,777,216 |
| runtime당 scrollback live rows | 100,000 |
| link entries / grapheme entries | 각각 1,000,000 |
| 단일 link UTF-8 | 1 MiB |
| 단일 grapheme cluster | 4,096 codepoint |
| link/grapheme aggregate payload | 각각 64 MiB |
| kitty decoded image aggregate | core의 runtime limit, 최대 320 MB |
| kitty APC/chunk parser buffer | core의 runtime limit, 최대 480 MB |
| kitty placement count | core의 1,024 |

codec은 envelope/section/TLV declared length뿐 아니라 decoded entry count와 aggregate bytes도 독립적으로 검사한다.
8 GiB는 malformed input을 막는 codec 방어 cap이다. 실제 live upgrade store는 64 MiB를 무조건 적용하고 primary와
backup 각각 `F_PREALLOCATE(F_ALLOCATEALL)`로 exact space를 확보한다. 64 MiB를 넘으면 side-by-side drain을 쓴다.
cap과 cap+1, `count × element_size` overflow, section 합계 overflow, allocation OOM-before-mutation을 fixture로 고정한다.

### 반드시 직렬화하는 상태

- `host_id`, runtime IDs, registry size/resize generation, runtime별 canonical grid size.
- `TerminalCore`의 화면·스크롤백·parser/UTF-8/CSI/OSC/DCS/APC 중간 상태와 모든 logical mode.
- link/grapheme/kitty image storage와 cell이 참조하는 stable ID 관계.
- cwd/title/SSH destination/semantic state와 generation counter. 여기서 cwd는 **셸이 OSC 7으로 보고한 값**뿐이다 —
  커널 조회(`proc_pidinfo`) 단계는 host-backed runtime에 없어서, 셸 통합이 없는 셸과 재개 Term은 host-backed일 때
  cwd가 비어 있다. 메우려면 관측 payload에 host가 측정한 cwd를 더해야 하고 그건 이 문서의 wire 호환 규약을
  건드린다(배경: [persistent-session-host.md](persistent-session-host.md) 머리말, 규칙: [editor-surface-dock.md](editor-surface-dock.md) §3.5).
- pending clipboard/notification/bell/agent observation처럼 중복 또는 손실이 사용자에게 보이는 상태.
- PTY child pid, process group 확인값, size, master-fd slot. `exited/closing/reaping`은 serializable logical state가
  아니라 모두 false여야 하는 eligibility/lifecycle guard다.
- runtime handle 재매핑에 필요한 runtime order와 next-handle lower bound.

host 쪽 `Surface.title/cwd/command/custom_name`은 handoff 권위가 아니다. 현재 host surface의 해당 값은
`Surface.init` 기본 placeholder이고 실제 자동 제목·cwd·SSH 목적지는 `TerminalCore`, 사용자 이름·spawn command는
workspace/app 계층이 권위다. 따라서 handoff는 `Surface.id`와 `TerminalCore`만 기록하고 surface metadata는 publish 때
기본값으로 재구성한다. `process_state`는 저장값이 아니라 quiesce eligibility에서 `.running`임을 검사한 뒤 `.running`으로
재구성한다.

### 새 process에서 재구성하는 상태

- allocator, mutex, condition variable, thread, self-pipe, hash-map bucket allocation.
- `CoreOwner` debug owner, dirty/projection/reflow scratch buffer, renderer/client delta base.
- connection, stream ID, controller/observer attachment와 `controller_generation`. v1 precondition상 attachment와
  authority event queue가 모두 비어 있어 stale event receiver가 없으므로 새 host graph의 controller generation은 0에서
  다시 시작한다.
- foreground-process cache. restore 뒤 lazy refresh한다.

### encode 전에 비워야 하는 상태

- reader stack/local buffer에 남은 처리 전 PTY bytes.
- PTY로 쓰지 못한 response/input/core command.
- 실행 중 callback 또는 registry mutation.

wire DTO/tag/version은 이 native owner-field inventory와 독립된 명시적 계약이다. inventory field 이름·배치에서 tag를
자동 생성하지 않는다. 그래야 native field rename/reorganization이 N-1 wire 호환성을 조용히 깨지 않고, schema 변경은
명시적 converter와 version bump를 요구한다.

derived map은 store에서 재구성하되 duplicate/cell reference를 검증한다. `TerminalCore`, `Screen`, `Scrollback`,
`PtySession`, reader/queue, `LivePtySession`, Surface/runtime link/owner registry, `RuntimeManager`, host registry/socket에
필드가 추가되면 handoff inventory 분류가 없을 때 컴파일이 실패해야 한다. 분류는 `serialized`·`reconstructed`·
`inherited_resource`·`must_be_empty` 중 정확히 하나다. “기본값이면 괜찮다”는 암묵적 누락을 허용하지 않는다.

`serialized`는 native backing struct dump를 뜻하지 않는다. 예를 들어 scrollback page는 `head` 이전 descriptor와
미참조 arena cell에 이미 evict된 output이 남을 수 있으므로, codec은 `evicted_abs`부터의 **live row cells/wrap/prompt/
absolute identity만** 기록하고 target의 page layout을 새로 만든다. stale arena bytes와 allocator layout은 handoff에
쓰지 않는다.

## 9. `exec`와 fd 소유권

- preflight 동안 모든 fd는 계속 `CLOEXEC`다.
- exec 직전에 원본 fd는 `CLOEXEC` 상태로 유지한 채 PTY master, primary/backup handoff, lifetime `owner.lock`만
  예약된 allowlist slot으로 `dup`한다. 그 slot에만 `CLOEXEC`를 해제한다. `exec` syscall이 실패하면 slot을 전부
  닫고 원본 fd/reader/admission으로 재개한다.
- exec 전체 동안 lifetime `owner.lock` slot을 상속하고 discovery entry를 `restoring`으로 유지해 on-demand spawn
  경쟁을 막는다. 같은 major 중복 spawn만 막는 단기 `launch-v<major>.lock`은 상속하지 않는다.
- listen/client socket, wake pipe, trace/일반 file descriptor는 상속하지 않는다. exec 직전에는
  **`FD_CLOEXEC`가 꺼진 fd 3 이상 집합**이 allowlist와 정확히 같은지 검증한다(original PTY/owner fd처럼 계속 열린
  CLOEXEC 원본은 이 시점에 존재할 수 있다). target entrypoint 직후에는 **열린 fd 3 이상 집합**이 allowlist와
  정확히 같은지 별도로 검증한다. listener는 restore 때 같은 endpoint에 다시 bind한다.
  detached host의 fd 0/1/2는 기존 `/dev/null` stdio로 유지하며 inherited-resource allowlist 비교에서 제외한다.
- inherited master fd마다 `fstat` device/inode/rdev, character device, `O_RDWR|O_NONBLOCK`, winsize, unique slot을
  검증한다. `tcgetpgrp(master)`는 shell job control에 따라 pause 중에도 바뀌므로 durable identity나 strict equality
  gate로 쓰지 않는다. Child session/group 검증이 필요하면 `getsid(child_pid)`/`getpgid(child_pid)`를 별도 의미로
  사용하며, pre-commit 생존 probe는 `waitpid`로 exit status를 소비하지 않는다.
- 새 process는 새 wake pipe를 만들고 **paused reader thread 전부**를 준비한다. 모든 runtime
  decode/validation/allocation, listener 준비, paused-thread 생성과 start-gate 도달이 끝나기 전에는 master fd를
  read/write/resize하지 않는다. Target은 attempt 전체의 기존 absolute deadline 안에서 start-gate를 기다리고,
  그 만료는 one-shot rollback 사유다. Rollback은 이미 만료된 attempt deadline과 별개로 5초 recovery deadline을
  한 번만 받아 기다리며, 그 만료는 재귀 exec 없이 fail-stop한다.
- inherited allowlist slot은 target→staged-old rollback exec가 가능하도록 `committed` 직전까지 `CLOEXEC`를 다시
  켜지 않는다. rollback binary가 restore할 때도 같은 규칙을 지킨다.
- `committed`는 모든 runtime·listener·reader thread가 non-owning/prepared 상태로 준비되고 exact graph/owner/socket/
  manifest generation을 마지막으로 재검증한 뒤, host registry manifest를 target의 새
  protocol/build/upgrade epoch 또는 rollback의 exact 기존 build/protocol/codec/epoch identity와 `ready`
  lifecycle로 atomic republish하는 단 하나의
  irreversible point다. 성공 직후 child lifecycle ownership을 target/rollback graph로 옮기고, PTY master+
  primary/backup+owner inherited slot을 전량 닫아 fd 3 이상 non-CLOEXEC 집합이 비었음을 검증한다. 그 뒤에만 reader
  start gate를 release하고 rollback image promotion·attempt terminal ledger를 끝낸다. promotion 실패는 이미
  committed된 graph를 되돌리지 않고 다음 upgrade capability만 철회한다. 마지막으로 capability/wire status를
  게시하고 admission을 열어 accept loop를 시작한다. 첫 PTY read/write/resize, child reap, 외부 frame dispatch
  중 하나라도 일어난 뒤에는 rollback하지 않는다.
- `dup`/fd flag 설정 또는 `exec` syscall 자체가 실패해 old image가 재개될 때도 discovery manifest를 old
  protocol/build/upgrade epoch와 `ready` lifecycle로 atomic republish한 뒤 admission을 연다.
- target validation 실패 뒤 staged-old rollback `exec` syscall 자체도 실패하면 재귀 재시도하지 않고
  `rollback_exec_failed` fail-stop으로 끝낸다. 이 이중 실행 실패는 runtime 보존 보장 범위 밖이며 구조화 artifact만 남긴다.
- target의 shared deadline 초과는 rollback 사유일 수 있으므로 staged-old rollback role은 같은 만료값 때문에 입구에서
  다시 거부하지 않는다. old-side authority rollback과 동일하게 non-recursive recovery 한 번은 deadline 뒤에도
  수행하며, rollback role의 어떤 실패도 추가 exec로 이어지지 않는다.
- `waitpid`는 같은 PID host가 계속 소유한다. 별도 process가 같은 child를 reap하지 않는다.

## 10. 멀티윈도우·Quick Terminal·SSH

실행 중 Client transport reconnect와 host exec upgrade는 별도 state machine이며 동시에 commit하지 않는다. reconnect는
exact `host_id`의 existing endpoint에만 붙고 upgrade/spawn을 시작하지 않는다. host lifecycle가 `ready`가 아니거나
`upgrade_busy`면 per-host reconnect absolute deadline 안에서 기다리거나 unavailable로 끝낸다.
`pool_membership_generation`은 GUI HostPool entry add/remove, `connection_generation`은 같은 heap-pin HostAdapter 안의 Client
교체, `upgrade_epoch`은 같은 PID host image/handoff의 권위다. 셋은 서로 대체하거나 직접 비교하지 않는다. reconnect가
authority/publish 단계면 upgrade admission도 old/new connection generation이 정리될 때까지 busy로 닫는다.

- 같은 app process의 여러 Window는 app-global host connection을 공유한다. 정상 Quit 뒤 connection이 없어졌을 때만
  upgrade하므로 Window 수는 handoff 조건에 영향을 주지 않는다.
- 다른 Maru app process가 붙어 있으면 active attachment이므로 upgrade를 미룬다.
- workspace마다 저장된 `host_id:runtime_id`가 유지돼 재실행 뒤 각 Term이 원래 runtime에 다시 붙는다.
- Quick Terminal은 확정적으로 in-process이며 이 upgrade 대상이 아니다. session 설정과 무관하게 앱 Quit 때 종료하고,
  host graph·inventory·handoff codec·upgrade capability에 넣지 않는다.
- SSH에서 실행한 `maru attach`도 동일 UID observer/controller다. 붙어 있으면 upgrade를 미루고 연결을 강제로 끊지 않는다.

## 11. 단계와 종료 gate

### U0 — 소유 필드 inventory와 문서

- 모든 handoff 관련 owner type의 필드가 `serialized`·`reconstructed`·`inherited_resource`·`must_be_empty` 중
  정확히 하나로 분류된다.
- 새 필드가 미분류되거나 중복 분류되면 `test-session-host` compile이 실패한다.
- 제품 command/capability는 추가하지 않는다.
- U0 종료 때 side-by-side drain 대비 실제 사용자 가치, state 크기/시간 예산, codec 장기 유지비를 다시 검토한다.
  U0 통과만으로 U1 착수나 제품 migration 가능성을 승인하지 않는다.
- **소비 방식(실제 계약)**: U1 codec은 `handoff_inventory`의 **group 테이블을 직접 순회**한다
  (`handoff_codec`이 `inventory.terminal_core_groups`를 comptime으로 돈다). 한때 `dispositionOf(T, field)`라는
  per-field 조회점을 두고 "U1·U2가 이걸로 소비한다"고 적어 뒀지만 **어느 소비자도 쓰지 않았고**(도입 시점부터
  호출 0), 주석만 사실과 어긋난 채 남아 있어 제거했다(2026-07-28). 새 소비자도 테이블 순회를 쓴다 — per-field
  조회가 정말 필요해지면 그때 실제 호출자와 함께 되살린다(미리 두지 않는다).

### U1 — 순수 handoff codec

- bounded envelope/section/TLV codec과 current state DTO를 구현한다.
- 모든 logical state의 round-trip, malformed/duplicate/unknown-required/cap/checksum/OOM을 자동 검증한다.
- partial UTF-8와 각 parser state fixture를 별도 포함한다.
- **구현됨:** stable explicit tag의 `maru.host-handoff.v1`, host/runtime DTO, host-wide atomic decode,
  runtime identity/child/geometry/fd slot, compile-time serialized-field coverage, 대표적인 non-default
  `TerminalCore` parser continuation round-trip을 `test-session-host`가 검증한다. fail-every-allocation은 부분
  candidate를 publish하거나 누수하지 않는다. 모든 logical state를 non-default로 채운 exhaustive equality fixture는
  아직 남아 있으므로 U1 종료 gate는 열려 있다.

### U2 — quiesce/resume

- reader owned transfer state와 admission barrier를 구현한다.
- host가 attachment 0에서도 `PtyEventQueue`의 exit/read-error를 exact-once로 소비해 process state와 registry
  lifecycle을 전진시키는 owner drain을 구현한다. quiesce 중 child exit로 abort한 뒤 이 drain이 status를 한 번
  소비하고 같은 dead runtime 때문에 upgrade retry가 영구 abort하지 않는지 검증한다.
- quiesce 성공·deadline·queue full·continuous output·response pending 실패 주입에서 byte 순서와 재개를 검증한다.
- 아직 `exec`하지 않고 같은 process에서 quiesce→encode→resume한다.
- **구현됨:** socket frame admission gate, attachment/lifecycle 재검사, reader-owned response state,
  비파괴 pause/join/resume, GUI attachment 0의 owner event drain, 5초 cooperative-deadline coordinator를 연결했다.
  실제 PTY에서 같은 child PID/master fd 유지, continuous output, deadline rollback과 encode→resume를 검증한다.

### U3 — test-only 단일 runtime exec

- frozen old test binary가 controlled PTY를 만들고 새 test binary로 exec한다.
- host/child PID, runtime ID, screen/parser state, post-upgrade input/output, exit status exact-once를 artifact로 단언한다.
- 모든 old-image failpoint와 target rollback-handler 설치 뒤의 controlled pre-commit failpoint가 구 binary 재개
  또는 rollback exec로 돌아가는지 검증한다. loader/entrypoint 이전 crash는 host crash 비목표로 별도 표시한다.
- N-1→N 성공 뒤 rollback self-image가 N으로 회전하고, 이어진 N→N+1 controlled 실패가 N image로 rollback되는
  2회 연속 upgrade E2E를 포함한다. promotion 실패는 capability 철회와 runtime 무변경을 단언한다.
- **구현 중:** listener/accepted socket CLOEXEC, exec 직전 reserved PTY/state/owner slot만 non-CLOEXEC로 만드는 exact
  allowlist, exec 실패 slot rollback, child를 signal/reap하지 않는 `PreparedAdoption`, commit 전 PTY를 전혀 만지지
  않는 reader start gate를 구현했다. 별도 old/new process fixture에서 same-PID exec, 독립 primary/backup handoff,
  old-reader 전량 read-back, PTY·owner·backup fd를 받지 않는 독립 target preflight process, 실제 target
  decode/adopt 실패의 공통 rollback handler, PTY dev/inode/rdev 교체 거부, host/child/runtime identity,
  post-upgrade I/O와 exit exact-once, lifetime owner lease를 검증한다. target/self-image는 no-follow·same-UID
  검증 뒤 owner-only directory에 copy/hash/sync/atomic rename하며, 성공 target의 rollback image 승격과 promotion
  실패 시 capability 철회도 fixture로 고정했다. old가 기록한 staged target dev/inode/size/SHA-256을 new가 promotion
  전에 다시 대조하며 path replacement failure injection도 둔다. N-1→N commit 뒤 N image로 rollback self-image를
  회전하고, 같은 PTY로 N→N+1 controlled pre-commit 실패를 일으켜 N image로 rollback하는 2회 연속 process E2E도
  검증한다. 두 번째 attempt의 target preflight/`exec` syscall 실패는 이미 committed N owner가 inherited slot을 닫고
  같은 PTY에서 계속 serve하는 것도 별도로 검증한다. 다만 old fixture가 현재 native 모듈과 함께 재컴파일되므로
  frozen N-1 증거는 아니다. 서명된 frozen N-1/current 실행 파일을 받는 별도 opt-in 하네스가 non-empty 제품
  graph의 commit→reader release→재접속 성공 경로를 자동화했지만, 실제 release artifact로 통과하기 전에는
  제품 증거로 세지 않는다.

### U4 — 다중 runtime과 N-1 adapter

- 여러 runtime의 큰 scrollback/kitty/partial parser 상태를 한 attempt로 전량 옮긴다.
- current GUI→frozen N-1 host adapter→upgrade→current attach 제품 경계를 자동화한다.
- 한 runtime decode가 실패하면 어떤 runtime도 commit하지 않는다는 것을 검증한다.
- **구현 중:** connect errno와 handshake/protocol 실패를 typed outcome으로 분리해 endpoint 부재만 launch하고,
  permission/version/malformed peer는 spawn으로 우회하지 않는다. host ID별 heap-pinned client pool이 제품 client를
  `HostAdapter`를 통해 소유하고 runtime+host lease를 단일 entry로 묶으며, 제품 AppSession의 new spawn과 workspace
  capture/restore가 그 pool을 통하도록 바꿨다. `Client`는 선택한 current/N-1 major를 hello 범위와 모든 frame header에
  고정한다. 지원하는 frozen N-1 release는 hello에서 `screen_stream_v1_current_body`를 반드시 광고하며, 그
  `maru.screen-stream` v1은 body layout이 current v2와 같고 record version만 다르다. reader는 adapter가 선택한
  exact screen version만 받아 current DTO로 정규화한다. capability가 없는 과거 개발 중 MRSH v1이나 MRSH/screen
  version이 교차된 record는 구조적으로 정상처럼 보여도 fail-close한다. capability-tagged MRSH v1 socketpair peer의
  `runtime.attach` 응답과 v1 snapshot record를 current `RemoteRuntime`까지 실제로 적용하는 테스트도 둔다.
  backend process E2E는 실제 current daemon 두 개에서 host A/B spawn과 `runtimeHostId` seam을 검증하고, A를
  non-terminating detach한 뒤 spawn host가 B인 상태에서도 saved runtime을 exact A로 reattach하는지, A runtime을
  명시 종료하고 A client/pool entry를 제거한 뒤에도 B runtime 입력/화면이 지속되는지 단언한다. pool refcount는 live
  `RemoteRuntime.client` 메모리 borrow만 보호하며 daemon retirement의 SSOT가 아니다. old host 종료 가능 여부는 후속
  authoritative daemon runtime inventory가 판정한다. 실제 frozen old binary package와 current+old 동시
  AppSession/workspace restore E2E, non-empty 제품 multi-runtime exact reattach는 아직 남아 있다.

### U5 — 제품 활성화

- `host_exec_upgrade_v1`과 `host.upgrade.prepare`를 광고한다.
- 앱 재실행 connect 경로가 upgrade 가능/호환 attach/upgrade busy/legacy 불가를 구분해 notice와 구조화 로그를 남긴다.
- signed app update 전후 E2E와 soak가 통과한 뒤에만 자동 upgrade를 기본 활성화한다.
- **구현된 opt-in signed 성공 gate:** 아래 명령은 개발 fixture가 아니라 명시적으로 전달한 두 제품 executable의
  strict code signature와 exact designated requirement를 먼저 대조한다. N-1 daemon에 실제 `/bin/cat` runtime을
  spawn/attach해 화면 marker를 확인하고 attachment를 0으로 만든 뒤 `host.upgrade.prepare`를 보낸다. 재접속 뒤에는
  Unix peer PID, direct PTY child PID, `host_id`, `runtime_id`가 전부 같고 epoch/build가 current로 전진했는지,
  pre-upgrade 화면과 post-upgrade child output이 모두 보이는지, status가 `committed/none`이고 다음 upgrade
  capability도 유지되는지 단언한다. Harness 자체의 서로 다른 SHA/signature 확인만으로 두 입력이 실제 frozen
  N-1/current release이고 방향·인접성이 맞다는 provenance를 증명할 수는 없다.

  ```sh
  zig build test-session-host-signed-upgrade \
    -Dsession-host-signed-n1-exe=/absolute/path/to/n-1/maru \
    -Dsession-host-signed-current-exe=/absolute/path/to/current/maru
  ```

  결과는 `zig-out/session-host-signed-upgrade/summary.json`에 binary pathname 없이 두 SHA/build ID와 signer
  requirement digest를 기록하며 실행 시작 때 과거 summary를 제거한다. 두 옵션 누락, 동일 SHA,
  same-UID/no-follow executable 조건 위반, signer 불일치는 **skip이 아니라 실패**다. 하네스 본체는
  기본 `test-session-host`에서 항상 compile되고 순수 helper test도 실행한다. 저장소와 일반 CI에는 release
  signing identity/frozen artifact가 없으므로 signed process 본체는 opt-in이며, 실행하지 않은 상태를 green으로
  보고하지 않는다.
- **release provenance gate:** release job은 아래 `maru.session-host-release.v1` manifest와 signed 제품 executable을
  Release asset으로 보존한다. B의 manifest는 SemVer 산술이나 `latest` 조회가 아니라 exact A release를 predecessor로
  지목한다. B 검증기는 그 immutable A와 B 후보를 사용해 `A daemon spawn→B adapter attach→동일 PID exec→B GUI exact
  reattach`를 실행한다. 같은 source tree에서 이름만 바꾸거나 현재 native module과 함께 재컴파일한 fixture는 이 gate를
  만족하지 않는다. 이 gate의 frozen N-1 업데이트 호환성 책임은 유지한다. `default=false→true` 전환은 별도 G3 release
  백로그이며 현재 P1~P5 완료 조건이 아니다.

  manifest는 UTF-8 JSON object 하나와 마지막 LF 하나인 canonical writer output이다. object key는 아래 표의 순서로
  쓰고 parser는 모든 scope에서 duplicate·unknown key, trailing value, 잘못된 UTF-8과 정수 overflow를 거부한다. 보안 판정은
  JSON의 모양이나 asset 이름이 아니라 release/attestation이 결속한 manifest bytes와 각 SHA-256을 사용한다.

  | scope | 필수 필드 | 불변식 |
  | --- | --- | --- |
  | root | `schema`, `role`, `repository`, `release`, `source`, `build`, `compatibility`, `signing`, `assets`, `evidence` | `schema`는 exact `maru.session-host-release.v1`; `role`은 `a` 또는 `b`; B만 `predecessor` 추가 |
  | `repository` | `id`, `owner`, `name` | GitHub numeric repository ID와 exact `ohah`/`maru`; 이름 재사용이나 다른 repository의 attestation 거부 |
  | `release` | `id`, `tag`, `version` | `id`는 GitHub numeric release ID, tag는 exact `v<version>`; version은 repository의 version SSOT와 같음 |
  | `source` | `commit`, `tree` | full lowercase Git object ID; release tag가 exact commit을 가리키고 checkout tree와 같음 |
  | `build` | `workflow_ref`, `run_id`, `run_attempt` | artifact attestation의 repository·commit·workflow identity와 exact 일치 |
  | `compatibility` | `mrsh_major`, `screen_codec`, `handoff_reader_min`, `handoff_reader_max`, `app_host_abi` | frozen executable의 `protocol.version_major`, `screen_stream.codec_version`, `handoff_codec.reader_min/reader_max`, app ABI와 exact 일치; `min > max` 거부 |
  | `signing` | `bundle_id`, `bundle_short_version`, `bundle_version`, `team_id`, `designated_requirement_sha256`, `architectures`, `notarization`, `stapled` | plist, `codesign`, `lipo`, `spctl`/stapler 검증 결과와 exact 일치; architecture는 중복 없는 정렬 배열; `notarization`은 exact `accepted`, `stapled`는 true |
  | `assets[]` | `role`, `name`, `sha256`, `size` | role은 `universal_dmg`, `frozen_product_executable`, `evidence_summary`가 각각 exact 1; regular file bytes의 digest/size와 일치; basename만 허용; DMG에서 no-follow로 추출한 제품 executable bytes는 frozen executable asset과 동일 |
  | `evidence` | `test_uuid`, `summary_name`, `summary_sha256`, `result` | summary는 같은 후보 bytes를 실행한 결과이며 `result`는 exact `passed`; stale summary와 다른 test UUID 거부 |
  | B 전용 `predecessor` | `release_id`, `tag`, `commit`, `manifest_sha256` | 네 필드 모두 published immutable A와 exact 일치; A에는 이 scope가 없고 B에는 반드시 있음 |

  manifest 파일 자체는 `assets[]`에 넣지 않는다. 자기 digest를 자기 bytes 안에 넣는 순환을 만들지 않고, trusted workflow가
  canonical manifest bytes를 별도 필수 Release asset으로 첨부한 뒤 그 bytes를 subject로 한 artifact attestation을 발급한다.
  그 asset의 exact 이름은 `Maru-<version>-session-host-release.json`이다. `<version>`은 manifest의
  `release.version`과 repository version SSOT의 canonical 세 요소이고, release tag는 exact `v<version>`이다. 고정 이름이나
  tag에서만 유도한 이름을 허용하지 않는다. 따라서 다른 release의 manifest를 같은 draft에 끼워 넣거나 predecessor tag와
  manifest version을 갈아 끼우는 경우 이름·내용·tag 교차검증에서 모두 실패한다.
  다음 release는 predecessor release에서 이 manifest asset을 exact 이름으로 내려받아 SHA-256과 attestation subject를 먼저
  검증한 뒤에만 내부 `assets[]`를 해석한다. manifest asset 누락·복수·이름 불일치도 publication/consumption 실패다.

  parser/writer/policy의 단일 소유자는 OS 중립 `src/platform/macos/session_host/release_manifest.zig`이고, release job의
  executable adapter는 `tools/session-host/validate_release_manifest.zig`다. adapter는 GitHub API/`gh`·codesign·DMG 추출 결과를
  typed input으로 만들어 core validator에 주입할 뿐 JSON을 두 번째로 해석하지 않는다. compatibility와 signing 관측은
  공통 executable SHA-256으로 frozen executable asset에 결속하고, evidence schema/result 관측은 파싱한 summary bytes의
  SHA-256으로 evidence summary asset에 결속한다. runtime/GUI는 이 manifest를 읽지
  않으며 새 런타임 의존성도 추가하지 않는다. 이 모듈의 `max_manifest_bytes`(64 KiB), `max_evidence_bytes`(1 MiB),
  `max_scalar_string_bytes`(4 KiB), `max_asset_name_bytes`(255)가 입력 상한의 단일 출처다. release/run ID와 size는 nonzero u64,
  SHA-256은 exact 64 lowercase hex이며 checked 합산이 상한을 넘으면 allocation 전에 거부한다. focused gate
  `test-session-host-release-manifest`는 canonical round-trip,
  모든 scope의 duplicate/unknown/missing/type/range/cap, A/B predecessor 유무, asset role exact-count, basename traversal·symlink,
  SHA/size/signature/compatibility/attestation mismatch와 allocation fail-index에서 publication 0을 Debug·ReleaseFast로 검증한다.
  별도 workflow contract fixture는 draft 생성 전 publish, evidence 전 manifest 생성, 누락 asset, mutable A, `--clobber`, 임의 ref와
  unpinned third-party action을 거부한다.

  adapter CLI는 다음 두 command만 허용한다. 모든 option은 exact 1회이며 순서는 자유지만 unknown/duplicate/missing option,
  positional argument, 빈 값, symlink/non-regular input, 기존 output을 거부한다. artifact path는 CLI가 받고 GitHub identity를
  caller가 문자열로 주입하지 않는다. repository ID·owner/name, tag/ref, source SHA, workflow ref, run ID/attempt, event 종류는
  표준 `GITHUB_*` context와 GitHub API/attestation 결과를 서로 교차검증한다.
  `release_adapter_environment.zig`는 실행 프로세스의 환경에서 `release_adapter_context.zig`가 소유한 exact 11개 이름만
  직접 조회하고 즉시 typed context로 만든다. `release_adapter_context.zig`는 그 11개 context만 받아 missing·duplicate·unknown key와
  빈 값·제어문자·`max_scalar_string_bytes` 초과를 거부한다. `GITHUB_REPOSITORY`/numeric ID, canonical `vMAJOR.MINOR.PATCH`
  tag/ref, lowercase 40-hex SHA, exact release workflow ref, nonzero canonical run ID/attempt, `push`, protected ref를 하나의
  typed context로 만든 뒤 manifest의 repository/release tag/source/build와 exact 결속한다. 이 context는 프로세스 환경만으로
  GitHub service identity를 증명하지 않으며, GitHub API·attestation 교차검증이나 protected `release` environment 증거를
  대신하지 않는다.
  adapter observation이 공유하는 canonical tag와 lowercase hex 문법은 `release_adapter_identity.zig` 한 곳이 소유한다.

  GitHub REST 응답의 공통 envelope는 OS 중립 `release_adapter_github_json.zig` 한 곳이 소유한다. 응답은 그 모듈의
  `max_response_bytes`가 소유하는 64 KiB 이하의 JSON root 하나여야 하며 scalar cap은
  `release_manifest.max_scalar_string_bytes`를 재사용한다. endpoint별 additive API field는 허용하되 완전한 root 뒤 두 번째
  value나 trailing garbage는 거부한다.

  repository 응답의 의미 해석은 `release_adapter_github_repository.zig`가 소유하며
  `id`·`name`·`full_name`·`owner.login`은 missing·duplicate·wrong wire
  type을 거부한다. numeric ID는 nonzero JSON number여야 하고 textual owner/name/full_name의 내부 정합성과 앞서 캡처한
  `GITHUB_REPOSITORY_ID`·`GITHUB_REPOSITORY`에 모두 exact 일치해야 한다. 이 parser는 이미 획득한 bytes의 의미만 검증하며,
  bytes가 GitHub에서 왔다는 transport 증거나 `gh` executable의 권위를 대신하지 않는다.

  release 응답의 의미 해석은 `release_adapter_github_release.zig`가 소유한다. GitHub REST release schema의 `id` JSON number,
  `tag_name` string과 `draft`·`prerelease` boolean을 필수로 소비하며 missing·duplicate·wrong wire type을 거부한다.
  `immutable`은 GitHub OpenAPI가 property로 정의하지만 required 목록에는 넣지 않으므로 draft에서 absent 또는 false를 허용하고
  true는 거부한다. draft 후보는 exact nonzero release ID와 canonical tag가 일치하고
  `draft=true`, `prerelease=false`여야 한다. published predecessor는 manifest가 지목한 exact ID·tag와 일치하고
  `draft=false`, `prerelease=false`, `immutable=true`여야 한다. GitHub OpenAPI에서 `immutable`이 required field로
  선언되지 않았으므로 predecessor 응답에서 absent이면 Maru가 immutability를 추정하지 않고 거부한다. 근거는 GitHub REST API의
  [Release schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.yaml)다.
  release의 `target_commitish`는 기존 tag가 가리키는 commit의 증거가 아니므로 source 결속에 쓰지 않는다. exact tag ref를
  full lowercase source commit으로 해소하는 Git ref/tag API 판정자가 그 책임을 별도로 소유한다.
  이 parser 역시 이미 획득한 bytes의 component 의미만 검증하며 transport나 executable authority를 증명하지 않는다.

  Git ref와 annotated-tag 응답의 한 hop 의미 해석은 `release_adapter_github_git.zig`가 소유한다. ref 응답은 exact
  `refs/tags/<canonical-tag>`와 object의 lowercase 40-hex SHA를 결속하고 object type을 `commit|tag`로 닫는다. annotated-tag
  응답은 caller가 직전 hop에서 얻은 exact tag-object SHA를 self `sha`에 결속하고, 첫 hop에서는 release tag name도 self `tag`에
  결속한 뒤 다음 `commit|tag` target을 typed하게 반환한다. 후속 nested hop은 서로 다른 non-empty bounded tag name을 허용하되 관측값으로
  보존한다. additive API field는 허용하지만 consumed field의 missing·duplicate·wrong wire type,
  unknown object type, uppercase/잘못된 길이 SHA는 거부한다. 근거는 GitHub REST API의
  [Git Reference와 Git Tag schema](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.yaml)다.
  `release_adapter_git_resolver.zig`는 이 typed hop을 이어 lightweight tag 또는 annotated-tag chain이 manifest의 exact
  lowercase source commit으로 수렴하는지 결속한다. caller가 제공한 `Backing`의 `[]Sha` 길이가 annotated object 수의 정책 상한이며
  0도 direct-commit-only 정책으로 유효하다. final-address `Backing`은 exact 한 final-address resolver에만 결속되고 storage와 두
  owner의 비겹침과 결속 뒤 backing descriptor 불변을 고정한다. resolver는 self/earlier cycle,
  depth exhaustion, foreign current object/commit, replay와 copied owner를 terminal fail-close한다. 따라서 component가 임의 최대 깊이
  숫자를 만들지 않는다. caller가 선택할 제품 최대 깊이와 실제 API 호출 배선이 추가되기 전에는 source provenance가 완료됐다고
  주장하지 않는다.

  ```text
  validate_release_manifest pre-publish \
    --repo ohah/maru \
    --tag v<version> \
    --manifest <canonical-manifest-path> \
    --evidence <evidence-summary-path> \
    --dmg <universal-dmg-path> \
    --frozen-executable <extracted-product-executable-path> \
    --summary-out <new-summary-path>

  validate_release_manifest verify-predecessor \
    --repo ohah/maru \
    --tag v<version> \
    --manifest <downloaded-predecessor-manifest-path> \
    --work-dir <new-empty-directory> \
    --summary-out <new-summary-path>
  ```

  `pre-publish`는 current draft와 local candidate bytes를 검사하고 publish하지 않는다. `verify-predecessor`는 이미 published인 exact
  predecessor에서 manifest가 열거한 asset을 새 `work-dir`로 내려받아 `gh release verify`와 각 파일의
  `gh release verify-asset`까지 검사하고 release를 수정하지 않는다. 둘 다 성공 시 stdout이 아니라 `--summary-out`에
  `maru.session-host-release-validation.v1` bounded canonical JSON 하나를 원자적으로 만든다. publish 전 실패는 output 0이며,
  exclusive rename 뒤 parent `fsync`가 실패하면 새 output을 제거하고 parent를 다시 동기화하는 best-effort rollback 뒤 terminal
  failure다. 저장장치가 unlink/fsync까지 함께 실패한 경우에는 이미 게시된 이름의 부재를 거짓 보장하지 않는다. summary는
  audit 결과일 뿐 다음 command의 권위 입력이 아니다. 별도 observation JSON input 포맷을 만들지 않는다.

  로컬 artifact는 pathname을 `stat`한 뒤 다시 열지 않는다. absolute path의 모든 component와 final을
  `openat(O_NOFOLLOW)`로 내려가며, 최종 regular fd 하나에서 bounded bytes·size·SHA-256·device/inode identity를 만든다. 서로 다른
  option이 같은 device/inode를 가리키면 hardlink라도 alias로 거부한다. summary는 같은 방식으로 연 parent fd 아래 0600 temp를
  complete write·`fsync`·`close`한 뒤 macOS `RENAME_EXCL`로 absent final에만 게시하고 parent를 `fsync`한다. predecessor work-dir도
  안전하게 연 parent 아래 absent leaf에만 0700으로 만들며, 기존 file/directory/symlink를 재사용하지 않는다.

  외부 관측 명령은 shell 문자열이나 호출자 PATH로 실행하지 않는다. absolute executable과 고정 argv를 공용
  `bounded_process.zig`에 넘기고 stdin은 `/dev/null`, stdout/stderr는 하나의 exact-cap pipe로 제한한다. 성공은 monotonic
  deadline 안에 pipe EOF와 child exit 0을 모두 관측한 경우뿐이다. timeout·출력 초과·비정상 종료는 child가 만든 process
  group 전체를 SIGKILL하고 direct child를 reap한 뒤 fail-close한다. upgrade codesign도 이 동일 실행 경계를 사용한다.

  signing job은 GitHub Environment exact `release`를 사용한다. adapter는 caller가 설정한 `environment=release` 문자열을
  신뢰하지 않고, 현재 run/job의 deployment가 그 environment에 결속됐으며 repository의 protection policy가 적용됐음을 GitHub
  API에서 확인해 `PublicationObservation.protected_environment`를 만든다. 이 증거가 없거나 API가 불완전하면 fail-close한다.
  Environment REST 응답의 component 의미 해석은 `release_adapter_github_environment.zig`가 소유한다. exact nonzero
  environment ID와 `name=release`, `protection_rules[].{id,type}` 및 rule별 payload, nullable `deployment_branch_policy`의
  `protected_branches`/`custom_branch_policies`를 typed observation으로 보존한다. 알려진 rule type은
  `required_reviewers|wait_timer|branch_policy`로 닫고, endpoint가 나중에 추가한 rule type은 additive field처럼 허용하되
  보호 증거로 세지 않는다. consumed field의 missing·duplicate·wrong wire type, zero/duplicate rule ID, 같은 알려진 rule의
  중복, 1~43,200분 밖 wait timer, 1~6명이 아니거나 `User|Team`/nonzero ID가 아닌 reviewer, known rule에 맞지 않는
  payload, `branch_policy` rule과 nullable policy object의 불일치 및 두 branch-policy bool이 exact-one이 아닌 경우를 거부한다.
  이 parser는 환경에 구성된 보호 사실만 증명하며
  현재 workflow run/job이 그 환경의 deployment를 통과했다는 증거가 아니다. 후속 adapter가 current run/job deployment와 이
  observation을 결속하기 전에는 `PublicationObservation.protected_environment=true`를 만들 수 없다. 근거는 GitHub REST API의
  [Deployment environments schema](https://docs.github.com/en/rest/deployments/environments)다.

  A의 evidence는 default-false baseline·signed app quit/reattach 결과를 가리킨다. B의 evidence는 frozen A 호환성과
  default-on 제품 matrix를 모두 포함하는 aggregate summary를 가리키며, 그 summary가 다시 두 leaf summary의 SHA-256과
  동일 `test_uuid`를 결속한다. manifest 자체나 evidence를 build 뒤 사람이 고쳐 넣을 수 없도록 같은 trusted release run이
  생성하고 artifact attestation을 발급한다. attestation 검증은 repository·workflow·source commit과 subject digest를 모두
  policy input으로 사용하며 단순히 cryptographic valid만으로 통과시키지 않는다.

  publish 순서는 닫혀 있다. trusted tag workflow가 후보 bytes에 artifact attestation을 발급하고 draft release ID를 얻은 뒤,
  그 후보로 제품 gate를 실행해 evidence를 만든다. 그 다음에야 release ID와 evidence digest를 담은 manifest를 생성·attest하고
  manifest와 그 manifest가 열거한 모든 asset을 draft에 attach한다. draft를 다시 내려받아 pre-publish validator가 검사한 뒤에만 publish한다. immutable release
  attestation은 publish 뒤에만 생기므로 자기 publish의 선행조건으로 순환 참조하지 않는다. 대신 후보/manifest artifact
  attestation과 manifest digest가 pre-publish trust를 맡고, publish 직후
  `gh release verify`/`verify-asset`에 해당하는 검증이 tag·commit·asset 결속을 확인해 release audit artifact를 남긴다.
  B가 A를 소비할 때는 이 post-publish release attestation까지 필수다. 공개 뒤 검증 실패는 asset 교체나 `--clobber`로
  복구하지 않고 그 release를 실패 기록으로 보존한 채 새 version으로 다시 출하한다.

  이 순서의 policy도 manifest parser와 같은 `release_manifest.zig`가 typed `PublicationObservation`으로 단일 소유하며,
  외부 공개 진입점 `parseAndValidatePublication`이 canonical manifest/evidence와 publication transcript를 함께 판정한다.
  관측은 trusted tag push·protected tag/environment·third-party Action pin 여부, fork PR/`pull_request_target`/임의 ref와
  `--clobber` 사용 여부, B predecessor의 published+immutable 상태, draft에 붙은 manifest exact-one과 manifest가 열거한
  asset set, 그리고 위 단계의 exact 순서를 전달한다. policy는 단계 누락·중복·재배열, publish 전 재다운로드 검증 누락,
  publish 전 release attestation, publish 뒤 manifest/asset 변경을 모두 거부한다. adapter와 workflow가 이 typed policy를
  실제 GitHub 관측에 연결하기 전에는 component fixture만으로 release publication이 안전하다고 주장하지 않는다.

  ```mermaid
  flowchart TD
      BUILD["trusted tag workflow builds signed candidate"]
      CANDIDATE["candidate attestation binds workflow commit and bytes"]
      DRAFT["draft release allocates exact release ID"]
      PRODUCT["product gates create evidence for candidate bytes"]
      MANIFEST["manifest binds release ID assets and evidence"]
      ATTEST["manifest attestation binds final manifest bytes"]
      VALIDATE["downloaded draft assets pass pre-publish validator"]
      PUBLISH["publish immutable release"]
      VERIFY["release attestation verifies tag commit and assets"]
      CONSUME["next release consumes exact predecessor"]
      BUILD --> CANDIDATE --> DRAFT --> PRODUCT --> MANIFEST --> ATTEST --> VALIDATE --> PUBLISH --> VERIFY --> CONSUME
  ```

  release A asset의 보존 기간은 A를 predecessor로 지목하는 모든 B가 지원되는 동안이며, 지원 창 종료는 별도 release가
  더는 A를 predecessor로 지목하지 않고 rollback 정책도 종료했음을 먼저 게시한 뒤에만 가능하다. attestation이나 release
  asset을 임의 삭제해 지원 창을 조용히 줄이지 않는다. release workflow는 protected tag/release environment만 사용하고
  fork PR·`pull_request_target`·임의 `workflow_dispatch` ref에서 signing secret 또는 self-hosted Aqua runner를 열지 않는다.
  모든 third-party Action은 mutable major tag가 아니라 full commit SHA로 pin한다.
- **구현된 component seam:** attempt-key exclusive target staging, strict same-designated-requirement codesign authorizer,
  accepted/armed/running/terminal idempotency owner, exec를 넘는 checksummed attempt record, host/epoch/next-handle/live
  runtime/target/rollback-image identity 교차검증, descriptor-relative primary/backup commit, 64 MiB operational cap, exact disk
  preallocation, attempt 전체가 공유하는 absolute monotonic deadline, 동일 paused graph에서 outer handoff와 sorted
  attempt runtime set을 만드는 capture, 256 PTY+primary+backup+owner 259개 FD slot 선예약, unlink-before-exec FD pair와
  target/rollback restore role token을 자동 검증한다. 제품 daemon은 startup 때 canonical rollback self-image,
  same-designated-requirement target stager, controller와 completed marker outer loop를 준비하고 실제 product preflight/pathname
  executor를 old-side coordinator에 연결한다. real PTY 한 개의 callback fixture도 같은 coordinator 순서를 고정한다.
  exec-return 실패의 `unchanged_retryable`
  authority rollback은 최초 호출을 포함해 최대 3회 시도하고, 첫 호출 뒤 재시도는 남은 absolute deadline 안에서 최대
  2회만 수행한다. 성공하면 모든 259개 slot을 닫고 admission과 기존 reader를 재개해
  같은 PTY의 후속 입력이 실제 screen snapshot에 나타나는 데까지 검증한다. 임의 preexisting non-CLOEXEC fd는 exec 전에
  거부한다. 실제 `HostAuthority` adapter는 expected host/epoch/lifecycle/`authority_generation` CAS로 disk manifest와
  wire status를 함께 `ready↔restoring` 전이한다. source ready의 `authority_generation`과 registry
  `membership_generation`은 optional handoff field로 직렬화하며, target/rollback ready activation은
  ready→restoring→ready 두 commit을 반영해 authority generation을 checked `source+2`로 복원한다. 두 전환 예산이
  없는 `max-1` 이상에서는 durable restoring publish 전에 upgrade만 unchanged로 거부하고 기존 reader/admission을
  재개한다. Manifest/slot 작업 뒤 pathname exec 직전에도 같은 paused child/fd graph를 재검증한다.
  rollback reader thread는 전부 생성 성공시킨 뒤 authority를 `ready`로 CAS하고, 그 다음 release flag를 전량 게시한
  뒤에만 admission을 연다. 하나라도 thread를 준비하지 못하면 `runtime_resume_failed`로 기록하고 authority/gate를
  열지 않는다. `begin_restoring` 전 resume 실패는 기존 `ready` discovery를 그대로 두지 않고 expected
  host/epoch/lifecycle CAS로 `draining`을 durable publish한다. 이 fail-stop publish도 확정할 수 없으면 coordinator는
  `invariant_violation`을 반환하며 normal/restored daemon이 공유하는 outer loop는 이를 즉시 process fail-stop으로
  전환한다.
- `upgrade_bootstrap`은 별도 실행된 staged target에서 fd 3 외 descriptor를 거부하고, primary handoff와 embedded
  attempt record를 같은 decoder로 전량 읽어 host/epoch/sorted runtime 집합과 `std.process.openExecutable`이 연
  현재 process executable pathname object의 recorded inode/dev/size/SHA-256을 교차검증한다. Zig 0.16의 macOS
  구현은 `_NSGetExecutablePath` 결과를 다시 open하므로 이는 kernel-loaded image pin 증거가 아니다. 경로 문자열은 macOS의
  `/tmp`→`/private/tmp` 해소처럼 같은 vnode를 다른 철자로 표현할 수 있으므로 image 권위로 사용하지 않는다.
  `ProductPreflight`는 child stdio를 `/dev/null`로 고정하고 primary만 fd
  3에 전달하며, 같은
  absolute deadline 안에서 exit를 reap하거나 timeout이면 kill+reap한다. 실제 build된 `maru
  __session-host --upgrade-preflight 3` 성공과 같은 inode의 corrupt handoff 거부를 process test로 검증한다.
  `ProductExecutor`는 strict restore argv를 소유하고 같은 absolute deadline을 syscall 직전에 다시 확인한 뒤 pathname
  `execv`를 호출하며 반환은 old graph rollback의 `exec_failed`로만 처리한다.
- `entrypoint.Invocation`은 정상 daemon, preflight, restore target/rollback argv를 strict tagged union으로 파싱한다.
  absolute session/socket path, 32자리 lowercase host/attempt ID, bounded first slot과 trailing-argv 0을 한곳에서
  검증한다. 공용 `upgrade_fd_layout.Layout`이 producer/parser/bootstrap의 inclusive u16 slot 경계를 소유한다.
  `upgrade_bootstrap.readRestoreInvocation`은 서로 다른 inode인 primary/backup의 read-only unlinked provenance,
  embedded token, host/attempt/runtime slot 집합을 교차검증한다. Target은 두 copy의 exact bytes를 요구하고
  primary를 decode한다. Rollback은 primary가 손상돼도 독립된 backup을 authority로 decode한다. PTY는 실제
  `PreparedAdoption`과 같은 non-CLOEXEC·`O_RDWR|O_NONBLOCK`·winsize·child-liveness·서로 다른 master identity
  검증을 사용하고, owner fd는 session 경로의 exact inode/mode와 exclusive flock을 재확립한다. host-keyed socket
  경로까지 맞아야 exact inherited open-fd 집합을 borrowed view로 반환한다. Attempt record v3는 서로 다른 staged
  target과 canonical `<session>/hosts/<host>/rollback-current`의 path/dev/inode/size/SHA를 함께 고정한다.
  Bootstrap은 `std.process.openExecutable`로 다시 연 **현재 process executable pathname object** identity를
  target/rollback role identity에 결합한다. Product main과 같은 source/dispatch에 validation-only test 옵션만
  compile-time으로 켠 별도 artifact와 그 독립 rollback copy를 각각 `exec`해 zero-runtime target/rollback validation-only
  entrypoint 성공, rollback role의 target-image 오용 거부, primary-corrupt/backup-valid rollback 성공을 process
  test로 검증한다. 이때 primary를 zero-byte로 truncate해도 rollback은 그 fd의 owner-only/unlinked provenance만
  확인하고 backup을 독립 decode한다. `rollback_image.Authority`는 caller가 준 pinned running identity와 source를 대조한 뒤 owner-only
  current leaf에 copy/hash/sync한다. Promotion은 `promoted`, `unchanged_failure`, swap은 됐지만 capability 철회가
  필요한 `promoted_needs_poison`, `indeterminate`를 구분하고 post-swap failure에서 disk identity를 reconcile한다.
  swap 뒤 실패로 old executable이 target leaf에 남으면 `Authority`가 exact dev/inode cleanup handle을 인수해
  deinit 때 replacement를 건드리지 않고 residue만 회수한다. 제품 main은 `RestoreArmed→RestoreValidated` typestate,
  heap-pinned restoring manifest adoption, closed admission, non-owning prepared runtime graph와 reader start gate를
  실제 `RestoreActivation`에 연결한다. Target precommit 실패는 preallocated canonical rollback argv를 한 번만
  exec한다. 정상 target은 ready durable commit→child ownership→inherited fd close/empty scan→reader release→
  rollback image promotion→terminal ledger→capability/admission 순서로 활성화한다. Rollback role은 재귀 exec 없이
  기존 build/epoch ready authority로 같은 순서를 수행한다. `allow_validation_only_restore=true`인 별도 fixture는
  bootstrap만 검사하고, 제품 artifact의 zero-runtime process gate는 restoring manifest와 activation marker로 실제
  commit 경로와 rollback fallback을 구분한다.
- **제품 rollback activation 종료 gate:** target role의 primary handoff를 손상시켜 pre-commit validation을 실패시키고,
  target process가 attempt에 고정된 canonical `rollback-current` **제품 binary**를 정확히 한 번 `exec`하게 한다.
  rollback child는 validation-only fixture에서 종료하지 않고 backup handoff로 `RestoreActivation` 전체를 수행해
  기존 `host_id`·PID·epoch/build를 가진 `ready` manifest를 다시 게시하고 같은 endpoint에 listener를 bind한다.
  검증자는 activation marker나 socket pathname 존재만으로 성공을 판정하지 않는다. 실제 MRSH client로 재접속해
  peer PID와 `host.info`의 host/build/epoch, `host.upgrade.status`의 `rolled_back/restore_failed`, upgrade capability,
  `runtime.list`의 exact restored set을 읽은 뒤 연결을 정상 종료한다. 그 client가 빠진 뒤에만 bounded oneshot
  daemon 종료를 허용하며 child를 reap한다. zero-runtime 첫 gate는 exact empty list를 단언한다.
- **non-empty PTY rollback 종료 gate:** test runner가 PTY를 만든 뒤 다른 process에 fd만 넘기지 않는다. rollback과
  같은 PID가 될 supervised source-host process가 production `RuntimeManager`로 실제 PTY child를 spawn하고 quiesce·
  capture한다. target primary를 preflight 뒤 손상시켜 canonical product rollback을 실행한 다음, 검증자는 같은
  peer PID와 old build/epoch·`rolled_back/restore_failed`, exact runtime ID 하나를 확인한다. PTY child PID는 rollback
  host의 실제 direct child로 남아야 하며, attach snapshot에는 rollback 전 marker가 있어야 하고 새 input marker도
  같은 runtime에서 출력돼야 한다. 마지막에는 shell을 known exit status로 끝내고 host가 child를 reap해 runtime
  inventory에서 정확히 한 번 제거한 뒤에만 client/oneshot daemon을 종료한다. 단순 codec round-trip, parent가 test
  runner인 inherited PTY, 화면 marker만 보이는 fixture는 이 gate의 증거가 아니다.
  이 test-only 수명 제어와 marker 환경은 launcher가
  일반 detached product launch 전에 지우는 목록에 계속 포함하고, fixture가 직접 fork/exec한 owner-only 임시
  session/socket root에서만 허용한다. 따라서 ambient environment만으로 실제 사용자 daemon을 oneshot으로 만들거나
  성공 marker를 위조할 수 없어야 한다. zero-runtime gate는 `test-session-host-upgrade-product-rollback`에서
  canonical product rollback exec 뒤 동일 peer PID의 실제 client handshake, old build/epoch, `rolled_back/restore_failed`,
  upgrade capability와 exact empty inventory를 자동 검증한다. 따라서 zero-runtime의 실제 제품 rollback activation과
  listener 재접속은 구현·실행됐으며, 위 non-empty PTY 보존은 아래 남은 gate로 구분한다.
- **아직 미구현 또는 미실행인 제품 종료 gate:** release manifest로 provenance가 고정된 signed frozen
  N-1/current artifact를 사용한 위 성공 gate의 실제 통과, non-empty PTY rollback activation, 1개·최대치 근처
  multi-runtime의 제품 daemon→product restore→GUI exact reattach, manifest/reader/socket/FD/promotion 전 구간
  failure injection, 장시간 soak와 **업그레이드 결과 notice**가 남아 있다(자동 orchestration 자체는 GUI의
  connect 경로에 연결됐다 — 위 상태 블록). macOS 공개 API에는 fd-based
  exec가 없으므로 kernel-loaded-image pin은 목표에서 제거하고, 마지막
  pathname object identity 재검증+same-designated-requirement signer+same-UID owner boundary를 제품 계약으로 쓴다.
  이 종료 gate가 닫히기 전에는 U5 완료를 주장하지 않는다.

U5 제품 종료 gate가 닫히기 전에는 “구 host session migration 완료”를 제품/PR에 쓰지 않는다. 자동 시도가 기본
경로에 연결된 것과 “migration이 검증됐다”는 것은 다르다 — 전자는 연결됐고, 후자는 위 gate가 닫혀야 성립한다.
U1~U4와 현재 U5 component seam은 제품 완료가 아니라 기반 증거다.

## 12. 필수 적대적 검증

- encode 중 OOM, disk full, short write, sync/rename 실패, exec 실패.
- target corrupt/truncated/foreign schema/checksum, runtime 한 개만 손상.
- PTY output이 UTF-8/CSI/OSC/DCS/APC 한가운데에서 멈춘 상태.
- child가 quiesce 동안 계속 출력하거나 exit하는 경합.
- master fd가 닫히거나 다른 fd로 바뀐 상태, duplicate fd slot, 잘못된 process group.
- exec 후 open-fd exact allowlist와 master `CLOEXEC` 복구; listen/client/wake/trace/일반 file fd 상속 0.
- input/core-command fence, partial PTY write, query response backpressure.
- 0/1/N runtime, 최대 scrollback, images/links/graphemes, alt screen.
- restore 전/후 SIGTERM과 socket reconnect 폭주.
- child exit를 구/new path가 중복 `waitpid`하지 않는지.
- handoff artifact에 cwd/output/env secret이 남는지. 실패 artifact는 공통 redaction 정책을 통과한 synthetic fixture만 보존한다.

실제 old binary E2E 없이 unit round-trip만 통과한 상태는 codec 구현으로만 표시한다. 실제 app update 뒤 session 유지
완료 판정은 U5 제품 경계에서만 한다.
