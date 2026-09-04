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
> 전 구간 failure injection, 업그레이드 결과 notice와 soak gate도 열려 있으므로
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

connect-or-launch 결과는 최종 `Client`와 별개인 bounded `UpgradeNotice`를 함께 돌려준다. 이 값은 같은 앱 실행에서
실제로 선택한 기존 host 하나에 대한 결정만 담고, host scan 중 지나친 후보들의 진단을 합치지 않는다. 분류는 다음과 같다.

- `upgraded`: accepted 뒤 same `host_id`, target build와 증가한 epoch를 재검증한 연결을 채택했다.
- `upgrade_busy`: prepare가 attachment/connection 권위 때문에 rejected되어 side-by-side current host를 사용한다.
- `legacy_unavailable`: 호환 host가 `host_exec_upgrade_v1`을 광고하지 않아 기존 host를 건드리지 않고 side-by-side current
  host를 사용한다.
- `upgrade_failed`: accepted/completed 뒤 rollback·resume·nonretryable status, status 조회 실패 또는 bounded reconnect 실패로
  target build를 채택하지 못하고 side-by-side current host를 사용한다. wire report가 있으면 exact `AttemptStatus`와
  `AttemptReason`을 보존하고, 없으면 typed local failure를 보존한다.

`UpgradeNotice`는 process-global 변수나 로그 문자열이 아니라 `connectOrLaunchDetailed` 반환값이 소유한다. 호출자는 최종
current host 연결이 성공한 경우에만 그 값을 `AppSession`의 한 칸 pending state로 옮긴다. 첫 UI tick은 modal overlay가
없을 때 localized notice를 정확히 한 번 표시하고 값을 소비한다. 최종 current host 연결도 실패하면 “터미널이 앱 종료 뒤
유지되지 않는다”는 기존 host-connect failure notice가 더 강한 결과이므로 upgrade notice를 버린다. 정상 current-build
재사용과 upgrade 후보가 전혀 없던 fresh launch는 notice를 만들지 않는다. 구조화 로그와 화면 notice는 같은 typed
`UpgradeNotice`에서 파생하며, `host_id`와 status/reason 또는 local failure tag를 그대로 남긴다.

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
  strict code signature와 exact designated requirement를 먼저 대조한다. N-1 daemon에 종료 marker를 읽는 실제 PTY shell runtime을
  spawn/attach해 화면 marker를 확인하고 attachment를 0으로 만든 뒤 `host.upgrade.prepare`를 보낸다. 재접속 뒤에는
  Unix peer PID, direct PTY child PID, `host_id`, `runtime_id`가 전부 같고 epoch/build가 current로 전진했는지,
  pre-upgrade 화면과 post-upgrade child output이 모두 보이는지, status가 `committed/none`이고 다음 upgrade
  capability도 유지되는지 단언한다. 마지막에는 PTY 입력으로 child를 종료하고 typed inventory 연속 부재와 direct-child
  부재를 함께 확인한다. Harness 자체의 서로 다른 SHA/signature 확인만으로 두 입력이 실제 frozen
  N-1/current release이고 방향·인접성이 맞다는 provenance를 증명할 수는 없다.

  ```sh
  zig build test-session-host-signed-upgrade \
    -Dsession-host-signed-n1-exe=/absolute/path/to/n-1/maru \
    -Dsession-host-signed-current-exe=/absolute/path/to/current/maru \
    -Dsession-host-release-test-uuid=<trusted-run-lowercase-rfc4122-v4-uuid>
  ```

  결과는 `zig-out/session-host-signed-upgrade/summary.json`에 canonical v2 leaf로 binary pathname 없이 trusted run UUID,
  두 executable SHA와 signer requirement digest 및 제품 관측을 기록하며 실행 시작 때 과거 summary를 제거한다. 세 옵션 누락, 동일 SHA,
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

  이 순환의 bootstrap command/buffer 권위는 `release_adapter_github_manifest_download.zig`가 소유한다. current B
  manifest의 이미 검증된 `predecessor.tag`와 `predecessor.manifest_sha256`만 받아 tag의 canonical version으로 provisional exact
  `Maru-<version>-session-host-release.json` 이름을 만든다. command는 `/absolute/gh release download <predecessor-tag>
  --repo ohah/maru --pattern <escaped-exact-name> --output -` 하나이며 latest, caller filename/flag, `--dir`, archive와 clobber는
  없다. stdout은 `release_manifest.max_manifest_bytes` caller buffer 안에서만 빌리고 empty/cap/foreign capture, child failure와
  digest mismatch를 모두 거부한다. 이 단계의 이름은 다운로드 선택용 provisional identity일 뿐 최종 manifest identity가 아니다.
  manifest와 세 asset의 fixed argv·Go `filepath.Match` literal escaping은
  `release_adapter_github_download_command.zig` 하나가 소유해 두 download 경계의 option drift를 막는다.
  predecessor A의 `build.run_id`·`build.run_attempt`는 artifact attestation certificate의 exact run identity를 검증하는 데 필요하지만
  current B의 `predecessor`에는 없으므로, attestation보다 먼저 canonical bytes를 strict/intrinsic parse해 unauthenticated candidate를
  만든다. 이 parse는 pathname·size·asset download 권위를 게시하지 않는다. candidate A의 role=A와 predecessor 부재,
  `release.id`·`release.tag`·`source.commit`을 current B의 predecessor release ID/tag/commit에, provisional filename을 A의
  canonical `release.version`에, file SHA를 B의 `manifest_sha256`에 먼저 교차검증한다. 그 candidate에서 만든 exact repository/tag/
  source/build context와 fixed file name/SHA subject로 artifact attestation을 검증하고 file identity를 호출 전후 재검증한 뒤에만
  authenticated manifest로 승격한다. 그 뒤에만 내부 `assets[]`를 다음 downloader 입력으로 사용할 수 있다.

  성공 결과는 digest-bound bytes와 provisional name/SHA를 빌린 slice로 반환하며 파일을 먼저 게시하지 않는다. artifact
  attestation CLI는 absolute path를 요구하므로 후속 `release_adapter_github_manifest_file.zig`가 같은 bytes를 내용과 무관한
  fixed exact name 아래 먼저 materialize한다. JSON parse나 내부 `assets[]` 해석 전에 이 파일을 만드는 것은 허용하되, 경로·상한은
  bootstrap의 canonical tag/name과 `max_manifest_bytes`만 결정하고 JSON 내용은 filesystem allocation 권위로 쓰지 않는다.
  focused gate
  `test-session-host-release-adapter-github-manifest-download`은 exact name/argv, clean environment, supplied-buffer
  provenance, empty/oversize/digest mismatch/timeout/child failure와 tag/SHA malformed를 Debug·ReleaseFast에서 검증한다. 이 gate만으로
  artifact attestation, strict manifest parse/cross-binding, 세 asset download 또는 workflow composition을
  완료했다고 주장하지 않는다.

  전체 pre-publish owner가 쓰는 `fetchUntil`은 tag/SHA/token/output preflight와 pinned CLI owner를 포함한 모든 borrowed/mutable
  input의 메모리 disjoint 검증을 deadline·filesystem·child 접근 전에 끝내고, 같은
  final-address `Deadline`을 pinned CLI 재검증 전후에 확인한다. child에는 재검증 뒤 얻은 fresh remaining만 전달하며 scalar로 새
  expiry를 만들지 않는다. preflight 실패는 deadline·CLI·child 0이고, 재검증 중 만료는 child 0·downloaded bytes publication 0이다.
  child 뒤 supplied-buffer provenance·length·digest를 검증한 후에도 `Observed`를 반환하기 직전 같은 deadline을 한 번 더
  확인하며, 만료하면 caller-owned output buffer를 권위로 승격하지 않고 publication 0으로 닫는다. 기존 budget
  `fetch`는 독립 leaf 호환용으로 남는다. focused gate는 exact deadline identity, pre/post/publication 순서, 늘어나지 않는
  child budget, 중간·최종 만료와 product wrapper compile을 Debug·ReleaseFast에서 검증한다.

  predecessor manifest input composition의 단일 소유자는
  `release_adapter_github_predecessor_manifest_input.zig`다. authenticated current B에서 predecessor tag·release ID·commit·manifest
  SHA를 유도하고 current owner를 재검증한 뒤, workspace owner가 내준 exact `predecessor-manifest` absent child에서만
  download `fetchUntil` → descriptor-owned materialize → canonical A candidate parse/cross-bind → artifact `authenticateUntil`을 실행한다.
  download와 attestation은 같은 final-address deadline과 pinned CLI를 공유한다. A attestation context는 downloaded canonical
  candidate의 repository/source/build에서 내부 유도하되 B predecessor와 role-A/predecessor-absent/digest/name 결속을 통과하기 전에는
  권위로 게시하지 않는다. 과거 workflow의 `protected_tag` 상태는 현재 context나 현재 ruleset에서 소급 증명할 수 없으므로 predecessor
  소비 조건으로 만들지 않는다. 대신 authenticated current B가 exact A release ID/tag/commit/manifest SHA를 보증하고, A manifest
  artifact attestation이 그 canonical bytes와 repository/tag/source/build를 증명하며, 후속 release/asset attestation이 published immutable
  release와 열거 asset을 다시 결속한다. current publication admission의 protected tag 요구는 그대로 유지한다. 성공은 authenticated A와
  exact file cleanup authority만 final-address move-only owner에 남기며 caller buffer는
  즉시 재사용할 수 있다. invalid/copied current·pre-owned result·foreign workspace는 deadline/CLI/download/filesystem 0이고,
  parse/cross-bind/attestation 실패는 materialized file과 directory residue 0으로 정리한다. cleanup 실패는 성공으로 숨기지 않고 같은
  owner가 retry 권위를 보존한다. focused gate `test-session-host-release-adapter-github-predecessor-manifest-input`은 actual filesystem,
  buffer reuse, shared deadline identity, current/A drift, 각 단계 실패 cleanup과 product wrapper compile을 Debug·ReleaseFast로 검증한다.
  predecessor assets, 전체 pre-publish orchestration과 workflow/U5 E2E는 후속 범위다.

  manifest file owner는 absolute absent work-directory를 no-follow parent 아래 0700으로 exact once 만들고 provisional exact manifest
  leaf를 `O_CREAT|O_EXCL|O_NOFOLLOW` 0600으로 연다. bounded bytes 길이만큼 `F_PREALLOCATE`+`ftruncate`한 뒤 complete write,
  SHA 재검증, file/directory `fsync`, post-write pathname↔fd identity/type/size/link-count 1과 0400 mode를 봉인한다. 성공은
  absolute path/device/inode/size/SHA를 가진 move-only `ManifestFile`이고 artifact attestation과 strict parse/cross-binding이 끝난 뒤
  같은 open directory capability로 explicit cleanup한다. 어느 단계든 실패하면 기록한 inode만 제거하고 directory/parent를
  동기화한다. pathname이 기록한 inode와 달라졌거나 cleanup 권위를 확증할 수 없으면 foreign entry를 지우지 않고 terminal
  `CleanupFailed`로 남긴다. focused gate `test-session-host-release-adapter-github-manifest-file`은 actual exclusive file
  bytes/mode/identity와 성공 cleanup residue 0, copied-owner 거부, existing/symlink destination, digest/foreign-name/empty/oversize의
  filesystem publication 0을 Debug·ReleaseFast에서 검증한다. write·pathname identity drift 주입과 cleanup 불확실성의 foreign-entry
  보존은 이 gate가 아직 증명하지 않으므로 후속 composition gate 전에는 검증 완료로 세지 않는다.
  이 gate만으로 artifact attestation이나 manifest parse/cross-binding을 완료했다고 주장하지 않는다.

  manifest attestation composition의 단일 소유자는 `release_adapter_github_manifest_attestation.zig`다. 입력은 current B의 verified
  `predecessor`, bootstrap의 bounded bytes와 `ManifestFile` capability, checkout 전에 pin한 GitHub CLI authority 및 exact
  token/deadline이다. predecessor의 repository/tag/source/build context는 strict candidate에서 내부 유도하며, historical
  `protected_tag` 값을 입력받거나 참으로 합성하지 않는다.
  composition은 `release_manifest.parseCanonical`과 `release_adapter_github_attestation.verifyWith`를 재사용하며 JSON parser, attestation
  command 또는 certificate predicate를 다시 구현하지 않는다. composition은 attestation 호출 직전에 CLI authority를 다시 검증한다.
  unauthenticated `release_manifest.Parsed`와 attestation `Observed`는
  성공 전 외부에 노출하지 않고 모든 mismatch·allocation·child failure에서 함께 deinit한다. 성공 결과는 final-address owner에 결속된
  move-only `AuthenticatedManifest` 하나이며, 그 owner만 parsed manifest를 조회하고 후속 asset expectation을 만들 수 있다. copied/
  moved-from owner, role B candidate, candidate predecessor 존재, B↔A release/tag/commit/SHA/name mismatch, file identity drift, attestation
  subject/run/repository/workflow mismatch는 publication 0이다. caller는 성공·실패 뒤 `ManifestFile.cleanup` 권위를 별도로 보존한다.
  focused gate `test-session-host-release-adapter-github-manifest-attestation`은 strict candidate parse와 B↔A cross-binding, exact 기존
  attestation call, pre/post file revalidation, move-only publication, mismatch/child failure/allocation unwind를 Debug·ReleaseFast에서
  검증한다. 이 gate만으로 세 predecessor asset download·release `verify-asset`, git resolver 또는 final workflow 배선을 완료했다고
  주장하지 않는다.

  executable predecessor composition의 `authenticateUntil`은 상위 phase의 final-address `Deadline` pointer를 그대로 받는다.
  canonical parse·B↔A context/predecessor/file preflight 뒤 같은 deadline을 확인하고, pinned CLI 재검증 뒤 fresh remaining만
  attestation child budget으로 전달한다. 새 expiry나 앞 remaining 재사용은 금지한다. preflight 실패는 deadline·CLI·child 접근 0이고,
  CLI 재검증 중 만료는 child 0, parsed/attestation publication 0으로 닫힌다. child 뒤 manifest file을 다시 검증한
  후에도 결과 owner를 게시하기 직전 같은 deadline을 확인하며, 만료하면 parsed/attestation을 cleanup하고
  publication 0을 유지한다. 기존 budget entrypoint는 독립 leaf gate 호환용으로 남는다. focused gate는 exact deadline
  identity, stale budget 비전달, preflight·중간·최종 만료 cleanup과 product wrapper compile을 Debug·ReleaseFast에서 검증한다.
  deadline/result storage는 manifest file/input bytes, context/predecessor scalar, executable/token/output 및 production pinned CLI
  owner와 겹칠 수 없으며 이 alias는 parse·deadline·CLI·child 접근 전에 거부한다.
  predecessor download/release/assets 전체 deadline 배선은 후속 범위다.

  post-publish `verify-predecessor` manifest 인증도 같은 module이 소유하되 B→A 소비 entrypoint와 권위 입력을 섞지 않는다.
  `authenticatePublishedUntil`은 executable bootstrap이 인증한 현재 protected tag `Context`, caller가 no-follow로 읽어 private
  manifest file에 materialize한 exact bytes, checkout 전에 pin한 CLI, token과 같은 phase `Deadline`만 받는다. candidate는 role A,
  predecessor 부재여야 하며 repository·release tag·source commit·build identity를 current context와 exact 교차 결속한다. manifest
  filename과 file/content SHA도 candidate에서 유도한 artifact-attestation subject와 일치해야 한다. 과거 A를 검증하는 B 소비 경로와
  달리 current context의 `protected_tag=true`를 요구하고 `manifest.Predecessor`를 self-synthesize하지 않는다.

  성공은 기존 move-only `AuthenticatedManifest` owner로만 게시하여 후속 immutable release/tag-chain/asset composition이 같은 strict
  parsed manifest를 재사용한다. deadline/result/output은 bytes/file/CLI/token/context backing과 겹칠 수 없고 production pinned CLI
  owner도 deadline/result/output뿐 아니라 bytes/file/CLI/token/context backing 전부와 겹칠 수 없다. parsed manifest backing도 모든
  live 입력과 분리된 뒤에만 외부 권위로 진행한다. role B,
  predecessor 존재, context/filename/file drift, copied/pre-owned result, deadline/CLI/attestation 실패는 authenticated publication 0이다.
  focused manifest-attestation gate는 published-A success, B/self-predecessor 합성 거부, owner alias의 deadline/CLI/child 접근 0,
  protected/current context drift, shared deadline identity와 전 allocation fail-index를 Debug·ReleaseFast에서 검증한다. 이 gate만으로
  verify-predecessor 전체 transaction, executable/workflow 배선 또는 frozen U5 제품 E2E를 완료했다고 주장하지 않는다.

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

  validator executable은 `release_adapter_executable_bootstrap.current`로 command/context/pre-checkout CLI를 먼저 인증하고 exact
  `GH_TOKEN`을 읽은 뒤에만 phase storage와 product execution을 연다. command union이 `pre_publish`이면
  `release_adapter_pre_publish_product.run`, `verify_predecessor`이면
  `release_adapter_verify_predecessor_product.run`을 exact once 호출하며 fallback, 두 phase 연속 실행, caller-selected driver는 없다.
  두 phase는 executable SSOT `phase_budget_ns = 20 * std.time.ns_per_min`을 공유한다. budget은 CLI option이나 환경변수로 완화하지
  않고 release workflow의 validator step/job timeout은 최소 25분으로 두어 process-group kill/reap과 private cleanup 여유를 남긴다.
  timeout은 summary publication 0인 재시도 가능한 release validation 실패이며 이미 공개된 release 성공으로 바꾸지 않는다.

  caller-owned `Storage`는 GitHub capture, manifest download, artifact attestation, compatibility와 Apple command capture를 각 하위
  component 상한에서 고정 배열로 분리하고 서로 alias하지 않는다. executable은 stdout에 validation JSON이나 token을 쓰지 않고 성공은
  command의 exclusive `summary-out` 파일로만 관측한다. bootstrap/token/product 실패는 nonzero exit이며 product가 cleanup retry authority를
  반환하면 process exit 전에 `retryCleanup`을 exact once 시도하고, 재실패는 성공으로 바꾸지 않는다. focused gate
  `test-session-host-release-validator-executable`은 bootstrap→token→exact phase dispatch 순서, 고정 budget/storage caps, phase 교환·fallback 0,
  product failure 전파와 real production types compile을 Debug·ReleaseFast에서 검증한다. 실제 GitHub/Apple child와 workflow ordering은
  후속 release workflow/U5 gate가 소유한다.

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

  현재 workflow run 응답의 의미 해석은 `release_adapter_github_run.zig`가 소유한다. `id`와
  `run_attempt`는 JSON number인 nonzero 값으로 context의 exact build identity와 일치해야 하고, `event=push`,
  `head_sha=<context source commit>`, REST `path=.github/workflows/release.yml`,
  `status=in_progress`, `conclusion=null`, 빈 `pull_requests`를 함께 요구한다. `repository`와
  `head_repository`는 둘 다 null이 아닌 `{id,name,full_name,owner.login}`을 소비해 context의 exact repository와
  내부적으로 일치해야 한다. consumed field의 missing·duplicate·wrong wire type, fork/foreign head repository,
  완료됐거나 아직 시작되지 않은 다른 run, PR 결속, 다른 workflow/SHA는 fail-close한다. tag ref는 ref가 포함되지 않는
  REST `path`에 억지로 투영하지 않고, 앞서 검증한 `GITHUB_WORKFLOW_REF`의 exact tag binding을 함께 재검증한다. additive API field는
  허용한다. focused gate `test-session-host-release-adapter-github-run`은 정상 응답, cap, malformed/duplicate/trailing,
  모든 identity/lifecycle mismatch와 allocation fail-index를 Debug·ReleaseFast로 검증한다. 이 parser는 이미 획득한
  REST bytes를 현재 context에 결속할 뿐 transport 권위나 현재 job의 protected `release` environment 통과를 대신하지 않는다.

  release 응답의 의미 해석은 `release_adapter_github_release.zig`가 소유한다. GitHub REST release schema의 `id` JSON number,
  `tag_name` string과 `draft`·`prerelease` boolean을 필수로 소비하며 missing·duplicate·wrong wire type을 거부한다.
  `immutable`은 GitHub OpenAPI가 property로 정의하지만 required 목록에는 넣지 않으므로 draft에서 absent 또는 false를 허용하고
  true는 거부한다. GitHub의 tag-name endpoint는 published release 전용이므로 current draft는 그 endpoint에서 조회하지 않는다.
  checkout 전 pin한 CLI와 push 권한 token으로 paginated `GET /repos/ohah/maru/releases?per_page=100` 전체를 받고, REST 배열
  순서나 첫 page/latest를 신뢰하지 않은 채 exact nonzero release ID와 canonical tag가 같은 draft를 정확히 하나 찾는다.
  목록 전체가 bounded capture/flattening 상한을 넘거나 exact match가 없거나 복수면 fail-close한다. draft 후보는
  collection parser로만 만들며 scalar release parser는 published immutable predecessor만 받는다.
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

  GitHub tag-chain transport composition은 제품 정책 상한을 annotated tag object **8개**로 고정한다. Maru release의 정상
  lightweight/단일 annotated tag를 수용하면서, attacker-controlled nested chain이 순차 API 호출과 파싱 비용을 무한히 늘리지
  못하게 하는 별도 상한이다. 첫 `tag_ref`와 각 `annotated_tag` 요청 직전에 checkout 전 pin된 CLI를 재검증하고, transport가
  반환한 bytes를 기존 Git ref/tag parser로 즉시 typed observation으로 만든다. parser 결과의 borrowed slice는 다음 요청에
  재사용되는 JSON buffer에 남기지 않고 fixed owned hop record로 복사한 뒤, 기존 resolver와 predecessor asset composition에만
  제공한다.

  최초 호출에서 만든 positive monotonic absolute deadline 하나를 모든 ref/tag fetch와 후속 세 asset download, release verify,
  세 verify-asset이 공유한다. hop이나 command마다 원래 budget을 새로 부여하지 않으며 CLI revalidation 뒤 남은 시간이 0이면
  child를 시작하지 않는다. lightweight tag는 annotated request 0회, annotated chain은 resolver가 요구한 exact object만 최대
  8회 요청하고 commit 도달 뒤 추가 caller observation이나 API 호출을 허용하지 않는다. 9번째 tag, cycle, foreign current object,
  manifest commit 불일치, CLI/path 교체, timeout과 borrowed-buffer mutation은 publication 0·download residue 0으로 fail-close한다.
  focused gate `test-session-host-release-adapter-github-tag-chain-transport`는 exact request sequence, 0/1/8-hop 성공, 9-hop/cycle/
  mismatch, CLI revalidation 횟수, single-deadline 감소·만료, response-buffer reuse와 allocation failure를 Debug·ReleaseFast에서
  검증한다. 이 composition은 repository/run/environment/deployment 관측, checkout 전 capture 자체, release workflow wiring과
  frozen U5 제품 E2E를 대신하지 않는다.

  predecessor asset composition의 executable `composeUntil`은 tag-chain과 같은 final-address `Deadline` pointer를 받는다.
  기존 `downloadAllWith`, release `verify`, 세 `verify-asset`의 parser·filesystem owner·cleanup 순서는 바꾸지 않고, 공통 guarded
  executor가 각 command마다 같은 deadline을 CLI 재검증 전후 확인한다. child에는 두 번째 fresh remaining만 전달하며 leaf가 받은
  원래 budget scalar나 앞 command remaining을 재사용하지 않는다. 외부 capture output은 result/authenticated owner,
  CLI path/token/workdir와 tag/ref observation storage 어느 것과도 겹칠 수 없다. authenticated/result/alias preflight 실패는 deadline·CLI·child 접근
  0이고, 어느 command 재검증 중 만료해도 후속 child 0, download directory residue 0, publication 0으로 닫힌다. 모든
  download/release/asset attestation과 tag resolver 수렴 후에도 guarded executor의 publication gate가 같은 deadline을 한 번 더
  확인한다. 만료하면 owned download set을 cleanup하고 directory residue 0과 result publication 0을 유지한다. 기존
  budget entrypoint는 독립 leaf gate 호환용으로 남는다. focused predecessor-assets gate는 7개 command의 exact deadline
  identity와 command 전후 14회+publication 1회 확인, 늘어나지 않는 budget, result/token/workdir alias 0-call,
  중간·최종 만료 cleanup, product wrapper
  compile을 Debug·ReleaseFast actual filesystem에서 검증한다.

  전체 predecessor transport의 executable `authenticateUntil`은 상위 phase의 final-address `Deadline` pointer를 받아 tag ref와
  최대 8개 annotated-tag request에서 CLI 재검증 전후 확인하고, resolver 성공 뒤 같은 pointer를 predecessor-assets
  `composeUntilWith`에 그대로 전달한다. transport는 remaining scalar를 downstream budget으로 바꾸거나 새 expiry를 만들지 않는다.
  tag response buffer는 result/authenticated owner, CLI path/token/workdir와 겹칠 수 없다. sink/result/manifest/alias preflight 실패는 deadline·CLI·child 접근 0이고, tag 구간 만료는 assets sink 0, assets 구간 만료는 기존
  download cleanup으로 residue 0이다. 기존 clock+budget entrypoint는 독립 gate 호환용으로 남는다. focused tag-chain gate는
  0/1/8-hop과 downstream command가 하나의 injected deadline identity와 non-increasing child budget을 공유하는지,
  result/token/workdir alias 0-call, tag→asset 경계 만료와 product wrapper compile을 Debug·ReleaseFast에서 검증한다.

  Current GitHub authority composition은 실행 프로세스에서 이미 strict parse된 `release_adapter_context.Context`와 checkout 전
  pin된 CLI를 받아 repository → workflow run → `release` environment → attempt jobs → source/tag/environment deployments 순서로
  closed REST request를 실행한다. 각 request 직전에 CLI pathname authority를 재검증하고 최초 positive monotonic absolute
  deadline 하나를 모든 request가 공유한다. 각 scalar response는 다음 request가 reusable response buffer를 덮기 전에 component
  parser가 allocation-owned typed observation으로 바꾸며, caller 문자열이나 REST 배열 순서를 권위로 사용하지 않는다.

  deployment join은 `release_adapter_github_deployment`가 두 단계로 소유한다. `prepare`는 attempt jobs와 deployments를 한 번만
  strict parse해 exact release job과 최대 `max_collection_entries` candidate deployment ID의 fixed ordered set을 소유한다.
  composition은 그 ID마다 `deployment_statuses`를 exact 1회 조회하고, `finish`는 candidate별 status backing의 누락·추가·중복을
  거부한 뒤 configured environment protection, exact job URL, official pending 이력과 exact-one in_progress를 한 deployment에
  결속한다. 성공 전에는 `protected_environment=true`를 만들지 않는다.

  결과는 final-address owner에 결속된 move-only `CurrentGitHubAuthority` 하나로만 게시하며 repository ID, run ID/attempt,
  source commit, job/deployment/environment ID와 affirmative protected-environment fact를 함께 보존한다. 이미 게시된 result,
  context/repository/run/environment/deployment mismatch, recognized protection 부재, 0개·복수 deployment match, candidate/status
  backing drift, response cap·pagination shape, CLI 교체, timeout, child/allocation failure는 첫 외부 호출 전 또는 publication 0으로
  fail-close한다. focused gate `test-session-host-release-adapter-github-current-authority`는 exact request/revalidation sequence,
  reusable buffer overwrite, status 0/1/100 경계, backing 누락·추가·중복, owner copy, single-deadline 감소·만료와 전 allocation
  fail-index를 Debug·ReleaseFast에서 검증한다. predecessor tag-chain/asset authority와 current authority의 최종 release command
  조립, checkout 전 capture 자체, Apple product 관측과 frozen U5 제품 E2E는 후속 범위다.

  Current release authority composition은 이 current authority와 current canonical manifest를 한 번에 결속한다.
  후속 executable pre-publish owner는 caller가 임의로 만든 parsed manifest를 받지 않는다. 먼저
  `release_adapter_github_current_manifest_candidate.zig`가 absolute canonical manifest pathname을
  `release_adapter_files.readInputAlloc`로 딱 한 번 no-follow bounded read하고, 그 owned bytes를
  `release_manifest.parseCanonical`로 해석해 final-address move-only `CurrentManifestCandidate`로 게시한다.
  외부 호출 전 이 candidate의 parsed manifest로 `release_adapter_context.bindManifest`를 수행해 repository/tag/source/build를 교차검증하고, current authority
  전체를 로컬 final-address owner에 성공시킨 뒤 authenticated paginated release 목록에서 exact manifest release ID/tag의
  mutable draft를 하나 찾고,
  `tag_ref` → 최대 8개 annotated-tag object를 조회해 manifest source commit으로 수렴시킨다. tag chain의
  fixed owned hop·cycle/depth/replay 정책은 predecessor와 current가 공유하는 하나의 helper가 소유하고,
  current composition이 동일한 resolver loop를 복제하지 않는다.

  최초 positive monotonic absolute deadline 하나를 repository/run/environment/deployment/status, draft release,
  ref/tag 전체가 공유하며 모든 request 직전 CLI pathname authority를 재검증한다. 성공은 move-only
  `CurrentReleaseAuthority` 하나로만 게시하고 current authority의 ID 전체, draft release ID/tag,
  exact source commit과 protected-environment fact를 함께 보존한다. pre-owned/copied result, manifest/context drift,
  mutable draft가 아닌 release, 9번째 tag, cycle/foreign commit, response backing overwrite, CLI 교체, timeout,
  child/allocation failure는 부분 current authority를 외부에 남기지 않고 publication 0으로 fail-close한다.
  focused gate `test-session-host-release-adapter-github-current-release-authority`는 exact 전체 request/revalidation 순서,
  lightweight/1/8-hop, 9-hop/cycle/mismatch, reusable buffer, 단일 deadline, copied owner와 전 allocation fail-index를
  Debug·ReleaseFast에서 검증한다. current manifest artifact attestation, local asset/Apple product 관측, summary publication,
  executable/workflow 배선과 frozen U5 제품 E2E는 여전히 후속 범위다.

  executable용 current release `...Until` entrypoint는 앞 단계의 current GitHub authority, mutable draft release 조회와
  shared `release_adapter_github_tag_authority` resolver까지 같은 final-address `Deadline` pointer로 연결한다. draft·tag ref·각
  annotated tag request는 CLI revalidation 전후 remaining을 확인하고 두 번째 값만 child budget으로 전달하며, tag resolver가
  depth마다 budget이나 expiry를 다시 만들지 않는다. 중간 만료는 이후 tag/API request 0, partial current/release/tag authority 0으로
  닫힌다. tag resolution 뒤에도 같은 deadline을 다시 확인한 뒤에만 최종 authority를 게시하므로 마지막 parse·cleanup 중 만료 역시
  publication 0이다. 기존 budget entrypoint는 독립 gate 호환용으로 남지만 전체 executable owner는 호출하지 않는다. focused current-release
  gate는 current authority부터 0/1/8-hop tag chain까지 하나의 injected deadline이 계속 감소하는지와 revalidation 중 만료를
  Debug·ReleaseFast에서 검증한다. manifest/asset attestation, Apple product와 compatibility의 `...Until` 이관은 후속 범위다.

  Current manifest attestation composition의 단일 소유자는
  `release_adapter_github_current_manifest_attestation.zig`다. 입력은 strict context, 앞 단계의 move-only
  `CurrentReleaseAuthority`, current B의 canonical manifest bytes, 그 bytes를 기존 0700 descriptor-owned workdir의 canonical
  `Maru-<version>-session-host-release.json` 0400·link-count-1 leaf로 materialize한 `ManifestFile`, checkout 전 pin한 CLI와
  token/deadline이다. caller가 준 원래 pathname을 `gh attestation verify`에 직접 넘기지 않는다. 원래 pathname은 검사 전후에
  교체했다가 되돌릴 수 있으므로 attestation child가 읽은 inode를 증명하지 못하기 때문이다. composition은 새 filesystem reader나
  attestation parser를 만들지 않고 `release_manifest.parseCanonical`, `release_adapter_context.bindManifest`,
  `release_adapter_github_attestation.verifyWith`, `ManifestFile.revalidate`를 재사용한다.

  외부 호출 전에 candidate가 role B이며 predecessor를 가지는지, context와 repository/tag/source/build가 일치하는지,
  current authority의 repository/run/attempt/source/release ID/tag/protected-environment가 candidate와 exact 일치하는지,
  canonical filename과 computed manifest SHA-256이 `ManifestFile` observation에 일치하는지 모두 닫는다. attestation 직전 pinned CLI를
  재검증하고, certificate·subject name/SHA·run attempt 검증 뒤 같은 directory capability로 file identity/type/mode/link-count/size/
  digest를 다시 확인한다. 성공은 parsed manifest와 current authority identity를 final-address owner에 함께 결속한 move-only
  `AuthenticatedCurrentManifest` 하나로만 게시한다. pre-owned/copied result, role A·predecessor 부재, context/current authority/file/
  attestation drift, CLI 교체, timeout, child/allocation failure는 publication 0이며 `ManifestFile.cleanup` 권위는 caller에게 남긴다.
  focused gate `test-session-host-release-adapter-github-current-manifest-attestation`은 fail-closed call order, before/after file drift,
  authority의 각 identity/protection mismatch, role/context/name mismatch, attestation failure, copied owner와 전 allocation fail-index를
  Debug·ReleaseFast에서 검증한다. certificate·subject 세부 변조는 재사용하는 artifact-attestation gate가 소유한다. local asset/Apple product 관측, summary publication,
  executable/workflow 배선과 frozen U5 제품 E2E는 여전히 후속 범위다.

  executable용 current manifest attestation `...Until` entrypoint는 current release가 사용한 같은 final-address `Deadline`을
  이어받는다. canonical parse·context/current/file preflight 뒤 deadline을 확인하고 CLI를 재검증한 다음 다시 remaining을
  구해 attestation child budget으로만 전달한다. child 뒤 private file을 재검증하고, 결과 owner를 게시하기 직전에도
  같은 deadline이 아직 유효한지 확인한다. local 작업을 이유로 expiry를 새로 만들거나, 만료된 attestation을
  성공으로 게시하지 않는다. preflight 실패는 deadline/CLI/child 접근 0이고, CLI 재검증 중 만료는 child 0,
  child 후 만료는 parsed/attestation owner를 cleanup한 뒤 publication 0으로 닫힌다. 기존 budget entrypoint는 독립 leaf gate
  호환용으로 남는다. focused gate는 shared deadline pre/post/publication 순서, stale budget 비전달, preflight·중간·최종 만료와
  owner cleanup을 Debug·ReleaseFast에서 검증한다. `CurrentManifestInput` candidate-consume
  wiring과 asset attestation, Apple product·compatibility `...Until` 이관은 후속 범위다.

  Current manifest pathname composition의 단일 소유자는
  `release_adapter_github_current_manifest_input.zig`다. 입력 manifest pathname은 absolute path와 canonical
  `Maru-<context version>-session-host-release.json` basename을 먼저 요구한다. 독립 leaf 검증용 pathname entrypoint와 별도로,
  executable composition이 사용할 entrypoint는 current release authority와 결속한 바로 그
  `CurrentManifestCandidate`를 consume한다. `CurrentReleaseAuthority.bindManifest`가 role B·predecessor 존재와
  repository/run/source/release/tag/protected environment를 exact 비교하고, mismatch에서는 candidate를 그대로 보존한다. 이
  preflight를 통과한 뒤에만 candidate가 소유하던 original input
  bytes·size·SHA-256·device/inode를 복사하거나 pathname을 다시 열지 않고 이전받는다.
  그 owned bytes와 computed digest만 `release_adapter_github_manifest_file.materialize`에 넘겨 caller가 지정한 absent
  work-directory 아래 0700 directory와 0400·link-count-1 canonical leaf를 만든다. 원래 pathname은 이후 attestation child나
  다른 parser에 다시 넘기지 않으며, 원본이 read 뒤 교체·삭제되어도 private leaf와 owned bytes가 같은 candidate를 가리킨다.

  성공은 original input bytes, cleanup 가능한 `ManifestFile`, 앞 단계의 `AuthenticatedCurrentManifest`를 final-address
  move-only `CurrentManifestInput` 하나가 함께 소유할 때만 게시한다. pre-owned/copied result, noncanonical basename,
  symlink·non-regular·empty·oversize·canonical parse 실패, already-consumed/copied candidate, destination collision,
  materialization/attestation 실패는 authenticated result 0이고,
  이미 만든 private file/work-directory와 input allocation을 역순으로 회수한다. cleanup 자체가 실패하면 성공으로 위장하지 않고
  같은 owner가 재시도 권위를 보존한다. focused gate
  `test-session-host-release-adapter-github-current-manifest-candidate`는 실제 macOS filesystem에서 canonical single-read 성공,
  basename/input/parse 실패, copied/pre-owned/consumed owner와 전 allocation fail-index를 검증한다.
  `test-session-host-release-adapter-github-current-manifest-input`은 실제 macOS filesystem에서 candidate consume 성공, attestor가 보는
  private path와 read 뒤 original mutation 격리, basename/input/path/materialization 실패, attestation 실패 뒤 residue 0,
  copied/pre-owned owner와 전 allocation fail-index를 Debug·ReleaseFast에서 검증한다. 이 composition은 local DMG/frozen
  executable·Apple product 관측, summary publication, executable/workflow 배선과 frozen U5 제품 E2E를 대신하지 않는다.

  executable용 `CurrentManifestInput.authenticateCandidateUntil`은 candidate preflight·one-shot input 이전·private file
  materialization까지 local ownership으로 끝낸 뒤, 앞 current release부터 이어진 같은 `Deadline` pointer를 current manifest
  attestation `...Until`에 그대로 전달한다. input composition은 remaining scalar를 읽거나 새 expiry를 만들지 않으며, consume 전
  실패는 candidate를 보존하고 consume 후 deadline/CLI/child 실패는 기존 역순 cleanup으로 input·private residue를 회수한다.
  nested manifest attestation이 게시된 뒤에도 outer `CurrentManifestInput` owner를 게시하기 전에 같은 deadline을
  확인하고 owned bytes·held private file·attestation 결속을 재검증한 뒤, owner 대입 직전에 deadline을 최종 확인한다.
  이 때 만료하거나 private leaf가
  바뀌면 nested owner, private file, input bytes를 모두 cleanup하고 candidate는 이미
  consume된 상태로 publication/residue 0을 유지한다. focused input gate는 exact allocation pointer 이전, deadline object identity 전달,
  consume 전 접근 0, consume 후 중간·outer publication 만료, outer publication 직전 실제 private inode mutation cleanup과 product wrapper compile을 Debug·ReleaseFast actual filesystem에서
  검증한다. asset attestation, Apple product·compatibility
  `...Until` 이관과 전체 owner는 후속 범위다.

  ```text
  validate_release_manifest pre-publish \
    --repo ohah/maru \
    --tag v<version> \
    --github-cli <pre-checkout-canonical-absolute-path> \
    --github-cli-sha256 <pre-checkout-lowercase-sha256> \
    --manifest <canonical-manifest-path> \
    --evidence <evidence-summary-path> \
    --dmg <universal-dmg-path> \
    --frozen-executable <extracted-product-executable-path> \
    --work-dir <new-empty-directory> \
    --summary-out <new-summary-path>

  validate_release_manifest verify-predecessor \
    --repo ohah/maru \
    --tag v<version> \
    --github-cli <pre-checkout-canonical-absolute-path> \
    --github-cli-sha256 <pre-checkout-lowercase-sha256> \
    --manifest <downloaded-published-current-manifest-path> \
    --work-dir <new-empty-directory> \
    --summary-out <new-summary-path>
  ```

  두 command의 `work-dir`는 caller가 고른 canonical absolute absent leaf이며 root·`.`/`..` component·중복/후행 slash는 filesystem
  접근 전에 거부한다. work-dir와 manifest/evidence/DMG/frozen executable/summary/CLI pathname은 exact equality뿐 아니라
  component-boundary ancestor·descendant 관계도 alias로 거부해 phase cleanup이 입력이나 출력을 포함하지 않게 한다. adapter가
  no-follow parent 아래 0700으로 만들고 한 phase owner가 성공·실패 cleanup을 끝낸다. ambient
  `TMPDIR`나 앱의 session-host 저장 경로를 추론·재사용하지 않는다. `pre-publish`는 current
  draft와 local candidate bytes를 검사하고 publish하지 않는다. `verify-predecessor`는 같은 trusted tag run이 방금 publish해
  향후 release가 predecessor로 소비할 exact role-A release를 검사한다. command의 `--tag`와 protected workflow context는 이
  published A 자신을 가리키며 아직 존재하지 않는 successor B나 B의 `predecessor` scope를 입력·합성하지 않는다. adapter는
  downloaded current A manifest가 current context와 exact 일치하고 artifact-attested인지 먼저 인증한 뒤 manifest가 열거한 asset을
  새 `work-dir`로 내려받아 `gh release verify`와 각 파일의
  `gh release verify-asset`까지 검사하고 release를 수정하지 않는다. 둘 다 성공 시 stdout이 아니라 `--summary-out`에
  `maru.session-host-release-validation.v1` bounded canonical JSON 하나를 원자적으로 만든다. publish 전 실패는 output 0이며,
  exclusive rename 뒤 parent `fsync`가 실패하면 새 output을 제거하고 parent를 다시 동기화하는 best-effort rollback 뒤 terminal
  failure다. 저장장치가 unlink/fsync까지 함께 실패한 경우에는 이미 게시된 이름의 부재를 거짓 보장하지 않는다. summary는
  audit 결과일 뿐 다음 command의 권위 입력이 아니다. 별도 observation JSON input 포맷을 만들지 않는다.

  pre-publish workspace filesystem owner는 `release_adapter_pre_publish_workspace.zig` 한 곳이다. caller의 absolute absent root를
  no-follow parent 아래 0700으로 만들고 parent/root의 device·inode와 held fd를 final-address move-only owner에 보존한다. 하위 단계는
  하위 단계는 이 owner가 재검증해 내주는 closed typed child만 받는다. pre-publish namespace는 `current-manifest`,
  `predecessor-manifest`, `predecessor-assets`, `dmg`, `current-assets`이고 baseline namespace는 `default-false`, `signed-app-quit`,
  `default-false.json`, `signed-app-quit.json`, `baseline-evidence.json`이다. child pathname은 각 child owner가 exclusive 생성할 입력이며,
  workspace owner는 생성 직후 root descriptor에서 identity를 먼저 봉인하고 pathname을 재검증한다. pathname stat 실패도 봉인된
  descriptor와 이름의 exact identity가 다시 일치할 때만 생성 root를 제거한다. child가 모두 정리된 뒤 exact empty root만 제거하고
  parent를 sync한다. copied/pre-owned owner, relative/root·leaf
  alias, parent/root replacement, unexpected entry와 cleanup 실패는 fail-close하며 cleanup 실패 시 같은 owner가 retry 권위를 보존한다.
  focused gate `test-session-host-release-adapter-pre-publish-workspace`는 실제 macOS filesystem에서 root mode/identity, pre-publish 다섯 canonical child,
  copy·replacement·occupied-child 거부, 성공 cleanup과 retry를 Debug·ReleaseFast로 검증한다. 이 substrate만으로 전체 phase orchestration이나
  child owner cleanup, workflow wiring과 frozen U5 E2E가 완료됐다고 주장하지 않는다.

  로컬 artifact는 pathname을 `stat`한 뒤 다시 열지 않는다. absolute path의 모든 component와 final을
  `openat(O_NOFOLLOW)`로 내려가며, 최종 regular fd 하나에서 bounded bytes·size·SHA-256·device/inode identity를 만든다. 서로 다른
  option이 같은 device/inode를 가리키면 hardlink라도 alias로 거부한다. summary는 같은 방식으로 연 parent fd 아래 0600 temp를
  complete write·`fsync`·`close`한 뒤 macOS `RENAME_EXCL`로 absent final에만 게시하고 parent를 `fsync`한다. predecessor work-dir도
  안전하게 연 parent 아래 absent leaf에만 0700으로 만들며, 기존 file/directory/symlink를 재사용하지 않는다.

  frozen executable처럼 manifest size가 큰 binary는 `readInputAlloc`로 전체 bytes를 heap에 올리지 않는다.
  `release_adapter_files.PinnedExecutableFile`이 caller가 준 absolute pathname을 no-follow로 열어 executable regular fd를
  final-address move-only owner에 보존하고, manifest의 nonzero expected size/SHA-256과 caller가 선택한 제품 상한을 먼저 결속한 뒤
  64 KiB 고정 stack buffer로 streaming hash한다. pin 전후 fd의 device/inode/type/mode/link-count/size/mtime/ctime이 같아야 하며,
  후속 DMG/Apple 관측 뒤 `revalidateExecutable`은 pathname hash·길이, reopened pathname fd, 보존 fd의 identity와 digest를 다시
  모두 대조한다. pathname 교체, in-place mutation, execute bit 제거, size/digest drift는 frozen asset 관측을 게시하지 않는다.
  성공/실패 경로에서 heap allocation은 없고 fd cleanup 권위는 원래 final address만 가진다. focused gate
  `test-session-host-release-adapter-frozen-executable-authority`는 actual macOS filesystem에서 exact success/revalidation,
  copied/pre-owned owner, relative/symlink/non-regular/non-executable, zero/cap/size/digest mismatch, pathname 교체와 in-place mutation을
  Debug·ReleaseFast로 검증한다. 이 gate만으로 DMG 내부 executable과의 동일성, Apple product 관측, current manifest composition,
  summary/executable/workflow 배선 또는 frozen U5 E2E를 완료했다고 주장하지 않는다.

  manifest를 만들기 전 release candidate file 권위는 `release_adapter_candidate_files.zig`의 final-address move-only
  `CandidateFiles`가 소유한다. 입력은 trusted tag `Context`, move-only `DraftAuthority`, final-address pre-draft
  `CandidateAttestation`과 그 owner가 이미 pin한 두 exact pathname뿐이다. caller가 size/SHA, release ID/tag/source, asset name이나
  attestation 성공 bool을 별도 scalar로 제출하지 않으며 raw pathname을 다시 pin하거나 large asset을 heap copy하지 않는다.

  composition은 attestation owner를 revalidate해 held fd digest·fingerprint·parent authority와 exact pathname identity를 다시 대조하고,
  그 view의 tag/source/build와 context, draft의 ID/tag/source를 교차결속한 뒤에만 owner를 게시한다. 성공 `CandidateFiles`는 attestation
  owner를 빌리므로 그 owner가 더 오래 살아야 하며 cleanup은 `CandidateFiles`를 먼저 닫고 `CandidateAttestation`의 fd authority를
  나중에 닫는다. copied/pre-owned/stale attestation owner, context/draft/path drift, pathname 교체와 in-place mutation에서는 publication
  0이다. focused gate `test-session-host-release-adapter-candidate-files`는 exact success/revalidation, owner lifetime, context/draft/path drift,
  mutation과 copied/pre-owned owner를 Debug·ReleaseFast로 검증한다. Apple signing·DMG 내부 executable equality와 evidence/manifest
  authoring은 후속 candidate product owner가 소비한다.

  pre-manifest Apple 제품 권위는 `release_adapter_candidate_product.zig`의 final-address move-only `CandidateProduct`가 소유한다.
  입력은 final-address `CandidateFiles`, 그 owner가 pin한 동일 DMG/frozen pathname, absent private DMG work pathname과 같은 release phase
  `Deadline`뿐이다. caller가 DMG size/SHA, executable SHA, version, signing이나 success receipt를 별도 제출하지 않는다. candidate files를
  child 전 재검증하고 그 view에서 DMG expected size/SHA와 tag version을 유도해
  `release_adapter_dmg_authority.observeUntil`을 실행한다. attach와 각 Apple 판정 명령은 같은 phase deadline에서 매번 fresh
  remaining을 얻어 시작하며, 이미 mount된 뒤 phase deadline이 끝나도 detach를 생략하지 않는다. detach만 상위 25분 job timeout 안의
  고정 4분 cleanup reserve를 사용하고 새 제품 판정은 수행하지 않는다. 남은 최소 1분은 process-group kill/reap과 private filesystem
  cleanup 여유이며 detach reserve로 전용할 수 없다.
  그 authority가 read-only private DMG mount, fixed product path, codesign/plist/lipo/staple/Gatekeeper 관측과 detach/cleanup을 소유한다.

  Apple observation과 detach/cleanup 뒤 같은 phase deadline을 다시 통과한 다음 `CandidateFiles`를 revalidate하고, DMG 내부 executable
  SHA가 held frozen executable SHA와 exact 일치해야
  한다. 성공 결과는 release ID/tag/source, candidate DMG/frozen 관측과 owned `apple_product.Observed`를 결속하며 signing은 이 owner의
  `Observed.signing()`에서만 유도한다. copied/pre-owned owner, files/path/work alias, deadline 만료, source mutation, Apple observation 실패,
  internal/frozen digest mismatch, cleanup 실패에서는 publication 0이다. focused gate
  `test-session-host-release-adapter-candidate-product`는 injected observer와 actual candidate filesystem으로 exact expectation/version/deadline,
  명령별 fresh remaining, deadline 만료 뒤 detach-only cleanup reserve, pre/post revalidation, copied owner,
  mutation·mismatch·failure와 allocation unwind를 Debug·ReleaseFast에서 검증한다. 실제 hdiutil/Apple
  command와 mount residue 0은 기존 DMG authority E2E가 소유하고, candidate artifact attestation과 evidence authoring은 후속 gate다.

  evidence와 manifest가 공유하는 source tree 권위는
  `release_adapter_github_source_tree.zig`의 final-address move-only `SourceTreeAuthority`가 소유한다. 입력은 trusted tag
  `Context`, checkout 전에 pin한 GitHub CLI, validated token, caller-owned bounded response storage와 같은 release phase
  `Deadline`뿐이다. 로컬 checkout, ambient `git`, caller-provided tree SHA를 권위로 사용하지 않는다. adapter는 context의 exact
  source commit으로만 `GET /repos/ohah/maru/git/commits/{commit}`을 구성하고, 응답의 top-level `sha`가 그 commit과 exact
  일치하며 `tree.sha`가 lowercase 40-hex일 때만 commit/tree pair를 게시한다.

  context/result/output alias와 malformed·duplicate/missing/wrong-type response는 child 전에 또는 parse 단계에서 fail-close한다.
  같은 deadline은 CLI 재검증 전, GitHub child budget 산출 전, child와 CLI 재검증 뒤 최종 publication 전에 확인한다. child가
  반환한 bytes는 caller output storage에서 빌린 exact slice여야 하며 foreign capture를 parse하지 않는다. copied/pre-owned owner,
  context/commit/tree drift, CLI 교체, timeout과 allocation failure에서는 publication 0이다. focused gate
  `test-session-host-release-adapter-github-source-tree`는 exact closed request와 deadline 순서, strict binding, capture/alias,
  copied owner와 allocation unwind를 Debug·ReleaseFast에서 검증한다. 이 gate는 evidence leaf 실행·aggregate authoring,
  manifest authoring, asset attach/publish 또는 frozen U5 E2E를 완료했다고 주장하지 않는다.

  manifest에 기록할 candidate compatibility는 caller 상수나 아직 존재하지 않는 manifest에서 읽지 않는다.
  `release_adapter_candidate_compatibility.zig`의 final-address move-only `CandidateCompatibility`가 exact frozen candidate를
  `__session-host --release-compatibility`로 한 번 실행해 유도한다. 입력은 `CandidateFiles`, `CandidateProduct`, 동일 candidate
  pathname과 release phase의 shared `Deadline`, caller-owned bounded stdout storage뿐이며 caller가 compatibility scalar나 성공 bool을
  제출하지 않는다. probe는 frozen executable의 held parent descriptor와 relative basename을 사용하고, 실행 전후 candidate product,
  held executable inode와 parent mutation seal을 재검증한다.

  canonical compatibility parser는 current-manifest 검증과 candidate authoring이 공유하는 단일 모듈이 소유한다. exact field set·순서,
  양의 schema/ABI 값과 reader min≤max만 허용한다. 성공 owner는 frozen SHA, release/source/build identity와 compatibility를 fixed storage에
  복사하며 후속 manifest writer 직전 같은 candidate graph를 다시 검증한다. copied/pre-owned/alias owner, foreign capture, timeout,
  malformed/noncanonical output, executable·parent·candidate drift에서는 publication 0이다. focused gate
  `test-session-host-release-adapter-candidate-compatibility`가 Debug·ReleaseFast에서 이를 검증한다. 이 gate는 manifest authoring,
  draft asset attach/publish 또는 signed frozen U5 제품 E2E를 완료하지 않는다.

  evidence writer에 넘길 current candidate 공통 identity는
  `release_adapter_candidate_evidence_identity.zig`의 final-address move-only `CandidateEvidenceIdentity`가 단독 소유한다.
  입력은 trusted `Context`, caller가 한 번 생성한 canonical UUID v4 correlation, final-address `CandidateFiles`와
  `CandidateProduct`, 동일 candidate pathname/DMG work pathname, `SourceTreeAuthority`뿐이다. caller가 release ID/version,
  commit/tree, candidate digest, build identity나 designated-requirement digest를 별도 scalar로 제출하지 않는다.

  composition은 candidate product를 원래 files/path authority로 재검증하고 source-tree commit을 context와 결속한 뒤
  repository/release/source/build/candidate와 product signing requirement를 fixed owner storage로 복사한다. UUID 형식과 공통
  identity 정책은 `release_evidence.validateCommon` 한 곳을 재사용한다. 후속 writer가 사용하기 직전 `revalidate`는 product와
  source-tree owner를 다시 대조해야 하며 copied/pre-owned owner, UUID/context/product/tree/path drift에서는 view를 내주지 않는다.
  focused gate `test-session-host-release-adapter-candidate-evidence-identity`는 exact common derivation, owner 독립 storage,
  copied/pre-owned owner와 UUID/context/product/tree/path drift를 Debug·ReleaseFast에서 검증한다. profile A/B 선택,
  predecessor authority, gate leaf 조립·publication과 aggregate attestation은 후속 gate가 소유한다.

  upgrade-B evidence가 소비할 predecessor 공통 identity는
  `release_adapter_predecessor_evidence_identity.zig`의 final-address move-only `PredecessorEvidenceIdentity`가 단독
  소유한다. 입력은 role-A `AuthenticatedManifest`, 그 인증 때 사용한 held `ManifestFile`, 해당 manifest로 만든
  `AuthenticatedPredecessorAssets`뿐이다. caller가 predecessor release ID/tag/commit, manifest/DMG/executable digest 또는
  다운로드 성공 bool을 별도 scalar로 제출하지 않는다. authenticated manifest는 parsed manifest와 attestation의 exact subject
  name/SHA, run identity를 함께 내는 read-only evidence view를 제공하되 raw parsed/observed field를 새 authority로 간주하지 않는다.

  composition은 manifest file과 downloaded set을 재검증하고, manifest가 canonical role A·predecessor 없음인지 확인한 뒤
  attestation subject digest↔held manifest digest, asset role별 manifest name/size/SHA↔downloaded inode observation,
  resolved source commit↔manifest source를 전부 교차결속한다. 그 뒤에만 `evidence.Predecessor`의 release ID/tag/commit,
  manifest SHA, DMG SHA와 frozen executable SHA를 fixed owner storage로 복사한다. 후속 upgrade writer 직전 `revalidate`는 동일
  세 owner와 held file/download inode를 다시 대조한다. copied/pre-owned/alias owner, authenticated observation drift,
  role/source/asset 교환·누락·digest/path identity 변화에서는 view publication 0이다. focused gate
  `test-session-host-release-adapter-predecessor-evidence-identity`는 exact derivation/revalidation, caller scalar 입력 0,
  manifest attestation/file mismatch, asset role 교환·mutation, copied/pre-owned/alias owner를 Debug·ReleaseFast actual filesystem에서
  검증한다. 이 gate는 upgrade 1/near-max leaf 실행·aggregate 조립, current manifest authoring, draft publication 또는 frozen U5
  제품 E2E를 완료하지 않는다.

  current local product composition의 단일 소유자는 `release_adapter_github_current_product.zig`다. 입력은 성공한
  `CurrentManifestInput` final-address owner와 caller의 absolute DMG/frozen executable pathname, private DMG work pathname뿐이다.
  composition은 unauthenticated manifest pointer나 caller가 별도로 조립한 asset expectation을 받지 않고, authenticated role-B
  manifest의 exact `universal_dmg`·`frozen_product_executable` asset name/size/SHA와 release version을 직접 빌린다. 두 input basename은
  manifest asset name과 exact 일치하고 private manifest/DMG work를 포함한 다른 pathname과 alias되지 않아야 한다. local release asset의
  공통 nonzero size ceiling은 `release_adapter_files.max_release_asset_bytes` 한 곳이 소유하며 predecessor downloader, DMG authority,
  frozen executable pin이 같은 값을 재사용한다.

  순서는 frozen executable no-follow pin과 첫 revalidation, read-only DMG staging/mount와 Apple product 관측, frozen executable 두 번째
  revalidation, DMG 내부 product executable SHA↔frozen SHA 대조, manifest `signing`↔Apple observation 대조다. signing equality는
  `release_manifest`의 기존 policy helper를 재사용하고 composition이 team/requirement/architecture 규칙을 다시 구현하지 않는다.
  어느 mismatch·allocation·mount·Apple command·detach·cleanup 실패에서도 product observation을 게시하지 않고, 성공 결과만 held frozen
  fd와 owned Apple observation을 하나의 final-address move-only owner로 보존한다. 후속 final observation 조립은 pathname이 아니라 이
  owner를 다시 revalidate한 view만 소비한다. focused gate `test-session-host-release-adapter-github-current-product`는 actual frozen
  filesystem과 injected DMG/Apple observer로 success, unauthenticated/copied/pre-owned owner, asset/path/cap/signing/digest mismatch,
  DMG failure 중 frozen mutation, cleanup과 allocation unwind를 Debug·ReleaseFast에서 검증한다. 실제 `hdiutil`·Apple command와 mount
  zero-residue는 기존 DMG authority component/E2E gate가 계속 소유한다. 이 gate만으로 compatibility/evidence/세 asset attestation,
  final manifest observation, summary/executable/workflow 배선 또는 frozen U5 E2E를 완료했다고 주장하지 않는다.

  전체 pre-publish phase용 executable entrypoint `observeUntil`은 앞 단계와 같은 final-address `Deadline` pointer를 받는다.
  result/current/path/manifest asset preflight는 deadline 접근 전에 끝내고, frozen executable pin 전에 같은 deadline을 확인한다.
  pin과 첫 filesystem revalidation 뒤에는 다시 remaining을 구해 그 fresh 값만 DMG/Apple observer child budget으로 전달한다.
  product composition은 새 시작 시각·expiry를 만들거나 pin 전 remaining을 재사용하지 않는다. preflight 실패는 deadline·pin·observer
  접근 0이고, pin 구간 중 만료는 observer 0과 held fd cleanup, publication 0으로 닫힌다. observer 성공 뒤에도 frozen
  executable을 다시 검증하고 결과 owner를 게시하기 직전 같은 deadline을 확인한다. 이 때 만료하면
  Apple observation과 held frozen fd를 모두 cleanup하고 publication 0을 유지한다. 기존 budget entrypoint는 독립 leaf gate 호환용으로
  남는다. observer 전후 current manifest의 owned bytes·private leaf 결속도 재검증해 child 중 manifest drift가 stale
  signing/asset 기대값으로 게시되지 않게 한다. focused gate는 exact deadline object identity, pin 전후 남은 값이
  늘어나지 않음, stale budget 비전달, preflight·중간·최종 만료 cleanup, 실제 child 중
  current bytes mutation publication 0과 product wrapper compile을 Debug·ReleaseFast actual filesystem에서 검증한다.
  deadline storage는 result/current/pathname storage 및 production Apple transport storage와 겹칠 수 없으며 이 alias는
  deadline·filesystem·observer 접근 전에 거부한다.
  compatibility `...Until` 이관과 전체 owner는 후속 범위다.

  current evidence provenance composition의 단일 소유자는
  `src/platform/macos/session_host/release_adapter_github_current_evidence.zig`다. 입력은 move-only
  `CurrentManifestInput` B, 그 B의 predecessor와 이미 교차결속된 move-only `AuthenticatedManifest` A, 그리고 caller의 evidence
  summary pathname뿐이다. caller가 repository/release/source/build/candidate/predecessor/signer expectation을 별도 scalar로 제출하는
  API는 두지 않는다. composition은 B manifest의 exact `evidence_summary` asset basename·size·SHA-256과 `evidence.summary_name`·
  `summary_sha256`을 먼저 같은 값으로 고정하고, summary를 `readInputAlloc(max_evidence_bytes)`로 한 번만 no-follow bounded read한다.
  B manifest input과 같은 opened `(device,inode)`인 summary는 role alias로 거부한다.

  canonical evidence를 strict parse한 뒤 B manifest에서 repository/release/source/build, universal DMG와 frozen executable candidate
  digest, `evidence.test_uuid`, `signing.designated_requirement_sha256`을 유도한다. A manifest에서는 exact release ID/tag/source commit,
  canonical A manifest digest와 A의 universal DMG/frozen executable digest를 유도한다. B의 predecessor 네 필드와 A의 role-A·
  predecessor-absent manifest를 다시 교차검증한 뒤 이 typed expectation으로 `release_evidence.bind(.upgrade_b)`를 호출한다. 성공은
  pathname이 아니라 owned summary bytes, computed file observation과 parsed evidence를 한 final-address move-only
  `CurrentEvidence`로 게시한다. copied/pre-owned/stale manifest owner, A/B swap, foreign predecessor asset, foreign signer, summary
  pathname·asset·manifest evidence drift, malformed/noncanonical bytes와 allocation failure에서는 결과를 게시하지 않는다.

  focused gate `test-session-host-release-adapter-github-current-evidence`는 Debug·ReleaseFast actual filesystem에서 success와
  move-only cleanup, caller pathname read 뒤 mutation 격리, manifest-summary inode alias, basename/size/SHA drift, A/B
  predecessor·candidate·test UUID·signer mismatch, malformed bytes와 allocation unwind의 publication 0을 검증한다. 이 gate는 summary
  artifact attestation, frozen executable compatibility observation, 세 current asset attestation, final
  `release_manifest.Observation`, workflow 배선 또는 frozen U5 E2E를 대신하지 않는다.

  current asset private-file composition의 단일 소유자는
  `src/platform/macos/session_host/release_adapter_github_current_asset_files.zig`다. 후속 GitHub artifact attestation 경계에 caller의
  DMG/frozen executable/evidence pathname을 직접 넘기지 않는다. child가 pathname을 여는 동안 같은 이름을 교체했다가 검증 뒤 되돌리면
  호출 전후 `stat`·hash만으로 child가 읽은 inode를 증명할 수 없기 때문이다. 입력은 authenticated `CurrentManifestInput` B,
  final-address `CurrentProduct`, final-address `CurrentEvidence`, caller의 DMG와 frozen executable absolute pathname, 그리고 absent private
  work-directory pathname뿐이다. caller가 asset name/size/SHA나 summary bytes를 별도 제출하지 않는다.

  composition은 B manifest의 exact 세 asset role을 이름 순서가 아니라 role exact-once로 유도한다. frozen source는
  `CurrentProduct.revalidate`로 held fd와 caller pathname을 먼저 결속하고, DMG source는 모든 path component를 no-follow로 열어 manifest
  size/SHA와 streaming hash를 결속하며, evidence source는 `CurrentEvidence`가 이미 소유한 bytes/size/SHA를 사용한다. current manifest
  input, DMG source, held frozen source, evidence source는 opened `(device,inode)` exact distinct여야 한다. 그 뒤 absent 0700 work-directory에
  manifest의 exact asset basename 세 개를 0400·link-count-1 regular private leaf로 complete copy하고 file·directory·parent를 sync한다.
  large DMG/frozen bytes는 heap에 올리지 않고 64 KiB fixed buffer로 복사하며, source와 destination의 size/SHA 및 source fingerprint를 복사
  전후 다시 대조한다. private leaf는 원래 caller pathname과 다른 inode여야 한다.

  성공은 세 private leaf의 진단용 pathname/device/inode/size/SHA, held directory fd와 cleanup authority를 한 final-address move-only
  `CurrentAssetFiles`로 게시한다. 진단용 absolute pathname은 child 입력 권위가 아니다. 후속 attestation composition은 이 owner가 살아 있는
  동안 `bounded_process`의 explicit held-directory API가 spawn file action `fchdir`로 child cwd를 그 exact directory vnode에 고정한 뒤
  `./<manifest-exact-name>`만 child argv에 넣어야 한다. child 종료 뒤 held directory와 세 leaf의
  identity를 다시 검증하기 전에는 attestation 성공을 게시하지 않는다. 현재 `bounded_process`의 우연한 open-fd 상속이나 private directory의
  ordinary absolute pathname을 이 계약의 대체물로 쓰지 않는다. 복사된
  owner, pre-owned destination, relative/aliased path, symlink·non-regular source, role/name/size/digest drift, pathname 교체·in-place mutation,
  short/extra write, destination collision, copy·sync 실패는 결과를 게시하지 않는다. 이 filesystem owner는 heap allocation 없이
  fixed storage만 사용한다. cleanup 실패는 성공이나 residue 0으로 위장하지
  않고 같은 owner가 exact retry authority를 보존한다. focused gate
  `test-session-host-release-adapter-github-current-asset-files`는 Debug·ReleaseFast actual filesystem에서 three-role success, move-only cleanup,
  source mutation/swap/alias, occupied·symlink destination, digest/size/role drift, copied/pre-owned owner, short/extra copy와 sync
  failure의 publication 0·cleanup retry를 검증한다. 이 gate는 GitHub attestation command/semantic verification, compatibility, final
  observation, workflow 배선 또는 frozen U5 E2E를 대신하지 않는다.

  `release_evidence.UpgradeExpected`는 manifest signing의 `designated_requirement_sha256`도 포함한다. canonical aggregate의 one/near-max
  두 signed-upgrade leaf는 서로 같은 requirement digest를 갖는 것뿐 아니라 이 exact expected digest와도 같아야 한다. 이전처럼 두
  leaf가 같은 foreign signer를 함께 기록하면 통과하는 상태는 허용하지 않는다. `release_evidence.bind`가 manifest/Apple product에서
  유도한 expected requirement를 받기 전에는 upgrade evidence를 최종 release observation으로 승격할 수 없다.

  외부 관측 명령은 shell 문자열이나 호출자 PATH로 실행하지 않는다. absolute executable과 고정 argv를 공용
  `bounded_process.zig`에 넘기고 stdin은 `/dev/null`, stdout/stderr는 하나의 exact-cap pipe로 제한한다. 성공은 monotonic
  deadline 안에 pipe EOF와 child exit 0을 모두 관측한 경우뿐이다. timeout·출력 초과·비정상 종료는 child가 만든 process
  group 전체를 SIGKILL하고 direct child를 reap한 뒤 fail-close한다. upgrade codesign도 이 동일 실행 경계를 사용한다.

  current asset attestation을 위한 descriptor-bound cwd도 `bounded_process.zig`가 소유한다. 새 explicit held-directory 실행 API는
  caller의 valid open directory fd 하나를 async-signal-safe fork child에서 `fchdir`해 child cwd를 exact vnode에 고정한다.
  child는 stdin/stdout/stderr를 결속한 뒤 fd 3 이상을 전부 닫아 ambient fd를 상속하지 않는다. macOS `/dev/fd/<n>`은
  directory descendant traversal을 제공하지 않으므로 `/dev/fd/<n>/<leaf>`를 권위 경로로 쓰지 않는다. caller directory fd의
  close-on-exec flag와 identity는 parent에서 바꾸지 않고 child 종료 뒤에도 caller가 소유한다. regular/stdio/closed fd,
  file-action/attribute/spawn 실패는 fork되지 않은 typed failure로 fail-close한다.

  focused gate `test-session-host-bounded-process`는 기존 cap/status/timeout/clean-environment 행과 함께 실제 temporary directory fd가
  child cwd로 고정되어 `./leaf`만 읽히는지, parent fd의 `FD_CLOEXEC`와 identity가 보존되는지, 별도 ambient sentinel fd가 child에서
  닫히는지, invalid/stdio fd가 fork 전에 거부되는지를 Debug·ReleaseFast 실제 process에서 검증한다. 이 substrate만으로
  `CurrentAssetFiles`와 artifact attestation의 semantic composition 또는 workflow/U5 배선을 완료했다고 주장하지 않는다.

  current 세 asset의 artifact attestation composition 단일 소유자는
  `src/platform/macos/session_host/release_adapter_github_current_asset_attestation.zig`다. 입력은 authenticated
  `CurrentManifestInput` B, final-address `CurrentAssetFiles`, checkout 전 pin된 GitHub CLI와 token뿐이다. caller가 context,
  asset expectation, pathname, directory fd나 command 순서를 별도 제출하지 않는다. composition은 B manifest와 그 authenticated
  authority가 같은 repository/tag/source/build/run-attempt임을 다시 결속하고, manifest의 세 role을 canonical role 순서로 exact
  once 유도한다. 최초 positive monotonic absolute deadline 하나를 CLI 재검증과 세 command가 공유하며, command마다 budget을
  재부여하지 않는다.

  각 command 직전에는 CLI authority와 `CurrentAssetFiles`의 held directory/세 leaf identity·0400 mode·link-count 1·size/SHA를
  재검증한다. child는 `bounded_process.runCaptureEnvironmentStdoutDirectory`로 held directory vnode를 cwd로 삼고
  `/absolute/gh attestation verify ./<manifest-exact-name> --repo ohah/maru --signer-workflow
  ohah/maru/.github/workflows/release.yml --signer-digest <source-commit> --source-digest <source-commit> --source-ref
  refs/tags/<tag> --deny-self-hosted-runners --predicate-type https://slsa.dev/provenance/v1 --format json`만 실행한다. ordinary
  absolute private pathname, original caller pathname, `/dev/fd` descendant와 inherited ambient fd는 child authority가 아니다.
  각 stdout은 기존 `release_adapter_github_attestation.parseAndBind`가 exact certificate/context/run/subject name·SHA에 결속하며,
  command 뒤 같은 filesystem owner를 다시 검증한 뒤에만 그 role을 게시한다.

  성공은 role별 `Observed` 세 개와 immutable manifest/context projection을 final-address move-only `CurrentAssetAttestations` 하나에
  exact once 게시한다. copied/pre-owned owner, role 누락·중복, manifest/current authority drift, private leaf 교체·rename·hardlink·
  mode/size/digest drift, CLI 교체, budget 만료, child/JSON/semantic failure는 결과를 게시하지 않고 이미 얻은 observation을 역순
  deinit한다. 이 composition은 private asset owner를 소비하거나 cleanup하지 않는다. focused gate
  `test-session-host-release-adapter-github-current-asset-attestation`은 Debug·ReleaseFast actual held-directory process와 injected
  attestor로 exact three-role order/argv/cwd, single-deadline 감소, CLI·filesystem pre/post revalidation, role/context/subject drift,
  copied owner와 allocation/command 실패의 publication 0·observation cleanup을 검증한다. 이 gate만으로 release `verify`/
  `verify-asset`, compatibility, final `release_manifest.Observation`, workflow 배선 또는 frozen U5 E2E를 완료했다고 주장하지 않는다.

  전체 pre-publish phase가 호출하는 executable entrypoint `composeUntil`은 앞 단계에서 시작한 final-address `Deadline` pointer를
  그대로 받는다. 각 role은 같은 deadline을 private filesystem과 CLI authority 재검증 전에 확인하고, 두 재검증이 끝난 뒤 다시
  확인해 얻은 fresh remaining만 attestation child budget으로 전달한다. role별 시작 시각·expiry를 만들거나 앞에서 읽은 remaining을
  재사용하지 않는다. current/result preflight 실패는 deadline·filesystem·CLI·child 접근 0이고, 재검증 중 만료는 해당 child와 뒤 role
  실행 0, 이미 얻은 observation 전부 cleanup, publication 0으로 닫힌다. 세 role을 모두 검증한 뒤에도
  결과 owner를 게시하기 직전 같은 deadline을 확인하며, 이 때 만료하면 세 observation을 모두 cleanup하고
  publication 0을 유지한다. 기존 budget entrypoint는 독립 leaf gate 호환용으로 남는다. focused gate는 세 role의 exact
  deadline object identity, 늘어나지 않는 fresh child budget, 중간·최종 만료와 product wrapper compile을 Debug·ReleaseFast에서
  검증한다. Apple product·compatibility `...Until` 이관과 전체 owner는 후속 범위다.

  frozen executable compatibility observation의 단일 소유자는
  `src/platform/macos/session_host/release_adapter_github_current_compatibility.zig`다. 입력은 authenticated
  `CurrentManifestInput` B, final-address `CurrentProduct`, caller의 frozen executable absolute pathname과 단일 positive monotonic
  budget뿐이다. caller가 compatibility 값이나 executable SHA를 별도 scalar로 제출하지 않는다. composition은
  `CurrentProduct.revalidate`로 held fd·pathname·manifest asset SHA와 held parent-directory identity·mode·mtime·ctime을 먼저
  결속한다. ordinary pathname 재해석은 상위 디렉터리 교체에 취약하므로, 이 probe만은 held parent-directory fd를 받은 뒤
  single-purpose adapter process에서 `fork`, child의 `fchdir`, pre-fork `getdtablesize` 상한까지 ambient fd `close`, exact
  `./<basename>` `execve` 순서로 실행한다.
  fork child는 allocator, logger, lock 또는 다른 비동기-signal-unsafe application 코드를 호출하지 않고 descriptor/process syscall만
  수행한다. argv[0]은 진단용 frozen absolute pathname을 유지하지만 실행 권위는 held directory vnode와 exact leaf다. child 종료 뒤 parent
  directory fingerprint까지 다시 같아야 하므로 실행 구간의 leaf 교체·복원도 publication 전에 거부한다. hidden probe는 frozen image에 컴파일된
  `protocol.version_major`, `screen_stream.codec_version`, `handoff_codec.reader_min/reader_max`, `app_session.abi_version`만 canonical
  bounded JSON 한 개로 stdout에 쓰며 argument, stdin, 환경 또는 filesystem을 compatibility 권위로 사용하지 않는다.

  probe stdout은 duplicate·unknown·missing field, trailing value, noncanonical integer와 zero/range overflow를 모두 거부하고
  `release_manifest.Compatibility`로 한 번만 materialize한다. child 종료 뒤 `CurrentProduct.revalidate`를 다시 수행하며 pre/post
  executable identity·size·SHA가 같고 parsed compatibility가 B manifest와 exact 일치할 때만 frozen SHA와 compatibility를
  `CurrentCompatibility` final-address move-only owner로 게시한다. copied/pre-owned owner, manifest/product/path drift, executable
  replacement·in-place mutation, timeout·output cap·child failure, malformed/noncanonical stdout와 compatibility mismatch는 publication
  0이다. focused gate `test-session-host-release-adapter-github-current-compatibility`는 actual separate process와 injected probe로
  exact argv/clean environment, canonical success, pre/post frozen revalidation, caller scalar 0, owner misuse, parser field/range drift,
  mutation·timeout·child failure의 publication 0을 Debug·ReleaseFast에서 검증한다. 이 gate만으로 final
  `release_manifest.Observation`, release `verify`/`verify-asset`, workflow 배선 또는 frozen U5 E2E를 완료했다고 주장하지 않는다.

  전체 pre-publish phase용 `composeUntil`은 앞 단계의 final-address `Deadline` pointer를 그대로 받는다. result/current/output
  preflight 뒤 같은 deadline을 확인하고, product held executable·parent directory·path mutation seal 재검증이 끝난 뒤 fresh
  remaining을 다시 구해 compatibility probe child에만 전달한다. 새 expiry나 앞 remaining 재사용은 금지한다. preflight 실패는
  deadline·product·probe 접근 0이고, product 재검증 중 만료는 probe 0과 publication 0으로 닫힌다. probe 성공
  뒤 path mutation seal, frozen executable과 current manifest 결속을 다시 검증한 후에도 결과 owner 게시 직전 같은 deadline을 확인하며,
  만료하면 publication 0을 유지한다. 기존 budget entrypoint는 독립 leaf gate 호환용으로 남는다. focused gate는 exact
  deadline identity, stale budget 비전달, preflight·중간·최종 만료와 product wrapper compile을 Debug·ReleaseFast에서
  검증한다. deadline storage는 result/current/product/output/frozen pathname storage와 겹칠 수 없고 이 alias는
  deadline·product·probe 접근 전에 거부한다. probe가 반환한 bytes는 caller output의 시작에서 빌린 bounded slice여야 하며
  foreign capture는 parse 전에 publication 0으로 거부한다. probe 중 current manifest drift의 publication 0도 같은 focused gate가 소유한다.
  전체 pre-publish owner 배선은 후속 범위다.

  current final manifest observation의 단일 소유자는
  `src/platform/macos/session_host/release_adapter_github_current_observation.zig`다. 입력은 authenticated
  `CurrentManifestInput` B, authenticated role-A predecessor manifest와 그 release/assets 검증을 보존한
  `AuthenticatedPredecessorAssets`, final-address `CurrentProduct`, `CurrentEvidence`, `CurrentAssetFiles`, `CurrentAssetAttestations`,
  `CurrentCompatibility`뿐이다. caller가 repository/release/source/build, boolean receipt, asset·signing·compatibility·evidence
  scalar 또는 predecessor publication 사실을 별도로 제출하지 않는다.

  composition은 모든 owner를 다시 조회하고 B의 current authority, A predecessor identity, predecessor download source commit,
  current asset-attestation context를 B와 exact 교차결속한다. current/predecessor manifest owner의 parsed value만 믿지 않고 내부
  artifact-attestation receipt가 존재하고 verified이며 exact run/subject에 결속된 상태인지도 다시 확인한다. `CurrentProduct`는 caller pathname 없이 held executable fd의
  identity/type/mode/link-count/size/SHA와 held parent authority를 다시 검증하고, `CurrentAssetFiles`도 held directory와 세 leaf를
  다시 검증한다. current manifest·predecessor manifest의 canonical owned bytes와 SHA,
  manifest/asset attestation, held frozen executable과 Apple product, strict evidence parse, compiled compatibility에서만
  `release_manifest.Observation`을 만든다. asset observation은 manifest role exact-once 순서를 사용하며 regular/no-follow는 private
  asset owner의 재검증 성공에서만 true다. Apple observation이 이미 증명한 strict signature·notarization·app/DMG staple·Gatekeeper와
  DMG no-follow extraction만 true로 materialize하고, predecessor published/immutable/release-attested facts는
  `AuthenticatedPredecessorAssets`가 다시 revalidate된 경우에만 materialize한다.

  조립된 observation은 `release_manifest.parseAndValidateObservation`에 current canonical bytes와 함께 즉시 넣고, 성공한 strict
  `Parsed`만 final-address move-only `CurrentObservation`으로 게시한다. output storage가 어느 입력 owner storage와 겹치면 입력을
  덮어쓸 수 있으므로 owner 조회 전에 거부한다. copied/pre-owned output, 어느 입력 owner의 copy·stale·context
  drift, A/B swap, manifest/asset/executable/evidence/attestation 불일치와 allocation failure는 publication 0이다. focused gate
  `test-session-host-release-adapter-github-current-observation`은 canonical success, 모든 input projection과 boolean의 derivation,
  copied/pre-owned/stale owner, output/input storage alias, role/context/predecessor/executable/evidence drift, strict validator rejection 및 allocation unwind를
  Debug·ReleaseFast에서 검증한다. 이 gate는 release workflow command ordering, draft redownload/publish, signed frozen U5 제품 E2E를
  대신하지 않는다.

  release validation audit summary의 canonical encoding 단일 소유자는
  `src/platform/macos/session_host/release_adapter_summary.zig`다. `pre-publish`는 final-address
  `CurrentObservation` B만, `verify-predecessor`는 authenticated role-A manifest와 그 manifest가 열거한
  published immutable release/assets의 held download 권위를 보존한 `AuthenticatedPredecessorAssets`만 받는다.
  caller가 manifest pointer, phase 문자열, 성공 boolean, digest·size·repository·release·source·build scalar를
  다시 제출하지 못한다. predecessor 경로는 manifest artifact attestation receipt와 downloaded asset set을
  encoding 직전·직후에 다시 검증하고 source commit과 manifest role를 교차 결속한다.

  output은 `maru.session-host-release-validation.v1` schema의 bounded canonical JSON이며 key 순서는
  `schema`, `phase`, `result`, `manifest_sha256`, `manifest_size`, `manifest`로 고정한다. `phase`는
  `pre_publish|verify_predecessor`, `result`는 검증 owner에서만 유도되는 `passed`다. nested `manifest`는
  strict parsed manifest 전체를 보존하고, `manifest_sha256`/`manifest_size`는 `release_manifest.writeCanonical`이
  만든 exact bytes에서 계산한다. role B는 `pre_publish`, role A는 `verify_predecessor`로만 encoding하며
  다른 조합은 거부한다. encoder는 LF 하나를 포함한 exact bytes를 만든 뒤 strict parser로 다시
  round-trip해 noncanonical key/order/escaping/number/trailing bytes와 digest·size·phase·manifest drift를 거부한다.
  `max_summary_bytes`는 `release_manifest.max_manifest_bytes`보다 크지 않은 별도 상한이고 allocation
  fail-index에서 output allocation은 전량 unwind된다. 이 bytes를 absent pathname에 exclusive·atomic publish하는
  filesystem 책임은 기존 `release_adapter_files.publishSummaryExclusive`에 남겨 encoder가 pathname을 받지 않는다.
  focused gate `test-session-host-release-adapter-summary`는 A/B exact canonical golden, owner copy/pre-owned/stale,
  role/phase/source/attestation/download drift, duplicate/unknown/missing/type/cap/trailing/noncanonical 변조와 전 allocation
  fail-index unwind를 Debug·ReleaseFast로 검증한다. summary는 감사 결과일 뿐 다음 command의 권위 입력이
  아니며, 이 gate는 executable·filesystem publication·workflow ordering·GitHub publish를 대신하지 않는다.

  release validation summary의 filesystem publication composition 단일 소유자는
  `src/platform/macos/session_host/release_adapter_summary_publication.zig`다. `pre-publish`와
  `verify-predecessor`의 production entrypoint는 각각 앞 절의 exact authenticated owner와 absolute absent
  `summary-out` pathname만 받는다. caller가 summary bytes, phase, 성공 boolean, digest·size 또는 별도 manifest를
  제출하는 API는 두지 않는다. composition은 owner에서 canonical summary를 allocation한 뒤 기존
  `release_adapter_files.publishSummaryExclusive`를 exact once 호출하고, 성공·실패 모두에서 bytes를 회수한다.
  encoding/owner 재검증이 실패하면 output pathname을 열지 않으며 publication 실패를 validation 성공으로 바꾸지 않는다.
  기존 destination은 regular file·symlink·directory 어느 것도 덮어쓰지 않고, 하위 file adapter의 0600 temp,
  complete write, file fsync, `RENAME_EXCL`, parent fsync 및 rollback 계약을 그대로 사용한다. 게시된 summary는
  strict parser로 읽을 수 있는 감사 출력일 뿐 후속 command의 authority input이 아니다.

  focused gate `test-session-host-release-adapter-summary-publication`은 실제 macOS filesystem에서 production
  `CurrentObservation` B의 exact bytes·0600 publication과 기존 destination 보존을 검증한다. injected owner/publisher로
  A/B phase별 encode→publish exact-once ordering, encode 실패 publication 0, publish 실패 전파, output byte lifetime 및
  allocation unwind를 Debug·ReleaseFast에서 검증한다. 하위 file adapter가 이미 소유하는 symlink component,
  temp write/fsync/rename/rollback fault matrix를 중복해 이 gate의 완료로 주장하지 않는다. 이 composition도 CLI option
  parsing, 전체 phase orchestration, workflow command ordering과 GitHub release publication을 대신하지 않는다.

  `verify-predecessor` phase transaction의 단일 순서 소유자는
  `src/platform/macos/session_host/release_adapter_verify_predecessor_phase.zig`다. validated token과 positive budget 뒤 같은
  final-address deadline을 시작한다. `startDeadline`은 실패 시 owner를 게시하지 않는 failure-pristine leaf여야 하며 그 첫 실패에는
  cleanup 대상이 없다. private workspace, current published role-A manifest candidate/materialization/attestation,
  immutable release·tag-chain·asset authentication을 닫힌 순서로 실행한다. 성공 owner에서 canonical summary bytes를 먼저 준비하되
  아직 output pathname은 열지 않는다. 그 뒤 asset, authenticated manifest, materialized file, candidate, workspace를 역순으로
  정리하고 live deadline을 최종 검증한 다음 deadline을 정리한다. 이 순서가 완전히 성공한 경우에만 prepared bytes를
  exclusive·atomic publish한다. 따라서 만료된 transaction이나 private cleanup
  failure와 `passed` summary가 공존하지 않으며 publication failure도 validation 성공으로 바뀌지 않는다.

  각 단계 실패는 뒤 단계와 summary prepare/publish 0이고 실패하면서 retry 권위를 남긴 attempted owner까지 역순으로 best-effort
  정리한다. cleanup failure는 원래
  오류보다 우선하며 실패한 owner의 retry authority를 보존한다. prepared summary bytes는 transaction이 유일하게 소유하고 publish
  성공·실패 모두 exact once 해제한다. focused gate `test-session-host-release-adapter-verify-predecessor-phase`는 exact step order와
  shared deadline identity, 모든 fail-index에서 attempted owner를 포함한 reverse cleanup, prepare 뒤 cleanup failure publication 0,
  final deadline 만료의 publication 0과 deadline/prepared bytes 해제, cleanup·최종 deadline 검증 완료 뒤 exact-one
  publication과 prepared bytes 해제를 Debug·ReleaseFast에서 검증한다. 이 gate는 leaf 의미 검증, production executable 배선,
  workflow ordering 또는 frozen U5 E2E를 대신하지 않는다.

  production `verify-predecessor` execution owner는
  `src/platform/macos/session_host/release_adapter_verify_predecessor_product.zig`의 caller-owned final-address `Execution`이다.
  executable bootstrap의 exact `verify_predecessor` command/context/pinned CLI, validated borrowed token, positive phase budget과 caller-owned
  bounded GitHub/attestation buffers만 입력으로 받고 앞 절 transaction의 각 step을 기존 production leaf에 직접 연결한다. `Execution`
  storage는 bootstrap/token/context/command/buffer와 겹칠 수 없으며 alias preflight는 deadline·filesystem·child보다 먼저다. command의
  manifest는 no-follow single-read candidate로 열고 input을 private workspace의 `current-manifest` child에 exact once materialize한 뒤
  current protected context의 published-A attestation을 수행한다. 인증된 manifest는 같은 deadline으로 immutable tag chain/release/assets를
  `predecessor-assets` child에 검증하고, summary bytes를 owner graph에서 준비한다.

  transaction의 private cleanup 뒤 `Execution`이 소유한 live deadline의 remaining budget을 최종 검증하고 deadline을 정리한 뒤에만
  command의 absent `summary-out`에 prepared bytes를 게시한다. foreign 또는 만료된 deadline은 publication 0으로 거부한다. 성공과 ordinary failure는 execution의
  private owner, deadline, prepared bytes와 borrowed bootstrap/token/buffer를 모두 비운다. cleanup failure 때만 아직 live인 child owner와
  cleanup allocator context를 같은 `Execution`에 보존하고 borrow는 즉시 지운다. caller는 `retryCleanup`으로 foreign pathname을 지우지
  않은 채 남은 owner를 정리해야 하며 그 전에는 execution을 재사용하거나 성공으로 처리할 수 없다. token/bootstrap/buffer 검증은
  manifest open, work-directory와 child 실행보다 먼저 일어나고, supplied buffers는 execution/bootstrap/token/context/command storage와
  서로 겹칠 수 없다. focused gate `test-session-host-release-adapter-verify-predecessor-product`는 invalid/copied/pre-owned execution의
  side effect 0, exact production type wiring, transaction delegation, owned deadline의 최종 만료/foreign 거부, success/ordinary-failure
  empty state, cleanup-failure retry state와 sensitive borrow scrubbing을 Debug·ReleaseFast에서 검증한다. 실제 GitHub child 성공은
  release workflow와 frozen U5 E2E가 소유한다.

  pre-publish phase transaction의 단일 순서 소유자는
  `src/platform/macos/session_host/release_adapter_pre_publish_phase.zig`다. validated token과 positive budget을 받은 뒤 deadline과
  private workspace를 exact once 만들고, current authority/candidate/input, predecessor input/tag-assets, current product/evidence/
  asset files/asset attestation/compatibility, final observation을 닫힌 순서로 실행한다. `startDeadline`은 실패 시 owner를 게시하지 않는
  failure-pristine leaf여야 하며, 그 첫 실패에는 cleanup 대상이 없다. 그 뒤 어느 단계든 실패하면 실패하면서 retry 권위를 남긴
  attempted owner까지 private owner를 역순으로 정리하며 뒤 단계와 summary publication은 0이다. final observation
  setup 실패도 observation cleanup을 먼저 수행한다. final observation 성공 뒤에도 summary를 먼저 게시하지 않는다.
  모든 child와 workspace cleanup이 성공한 뒤 live deadline을 최종 검증하고 deadline owner까지 정리한 뒤에만 observation owner에서
  summary를 게시하며, 마지막으로 observation을 해제한다.
  private cleanup 실패에도 observation owner는 terminal cleanup하고, cleanup 실패가 `passed` summary와 공존하지 않으며 cleanup retry
  authority는 실패한 child owner에 남는다.
  focused gate `test-session-host-release-adapter-pre-publish-phase`는 exact step order, shared deadline identity, 각 fail-index에서
  attempted owner를 포함한 reverse cleanup, observation setup 실패 cleanup, cleanup 실패 시 publication 0, private cleanup 뒤 final
  deadline expiry publication 0, deadline cleanup 뒤 publish와 terminal observation cleanup을 Debug·ReleaseFast에서 검증한다.
  이 transaction gate는 각 leaf의 의미 검증을 복제하지 않으며 production adapter 타입 배선과 signed frozen U5 E2E는 별도 gate가
  소유한다.

  production pre-publish execution owner는
  `src/platform/macos/session_host/release_adapter_pre_publish_product.zig`의 final-address `Execution`이다. executable bootstrap의
  exact `pre_publish` command/context/pinned CLI, validated borrowed token, positive phase budget, caller-owned bounded buffers와 Apple
  transport storage만 입력으로 받고 transaction의 각 step을 기존 production `...Until` entrypoint에 직접 연결한다. `Execution` storage는
  bootstrap/token/context/command/buffer/Apple storage와 겹칠 수 없으며 이 alias preflight는 deadline·filesystem·child보다 먼저다. workspace의
  다섯 child pathname 외 경로를 만들지 않으며 current manifest/evidence/DMG/frozen executable/summary pathname은 bootstrap command
  외 scalar 입력으로 다시 받지 않는다. private cleanup 뒤 `validatePublication`이 `Execution` 자체가 소유한 live deadline만
  받아 fresh remaining을 확인하며 foreign/expired deadline은 publication 0으로 거부하고,
  deadline cleanup 뒤 무효 capability를 summary publisher에 넘기지 않는다. 성공하면 모든 private owner와 deadline을 비우고 summary 하나만 남긴다. ordinary 실패도
  cleanup 성공 뒤 empty execution으로 돌아가며, cleanup 실패 때만 live child owner와 cleanup용 allocator context를 같은 caller-owned
  `Execution`에 보존한다. token/bootstrap/buffer/Apple storage/budget borrow는 실패 즉시 지운다. caller는 `retryCleanup`으로 foreign entry를 지우지 않은 채 남은 owner들을 다시 정리해야 하며 그 전에는
  execution을 재사용하거나 summary 성공으로 처리할 수 없다. focused product gate는 invalid/copied/pre-owned execution의 side effect
  0, exact production type surface, transaction delegation, owned deadline의 foreign/expiry 거부, 성공/ordinary-failure empty state와 cleanup-failure retry state를
  Debug·ReleaseFast에서 검증한다. 실제 GitHub/Apple child 성공은 release workflow wiring과 frozen U5 E2E가 소유한다.

  Apple 제품 관측의 component 의미는 `release_adapter_apple_product.zig` 한 곳이 소유한다. 이 판정자는 caller가 만든
  `Signing`을 받지 않고, frozen product executable의 SHA-256과 `/usr/bin/codesign -d --verbose=4`,
  `/usr/bin/codesign -d -r- --verbose=0`, `/usr/bin/lipo -archs`, `/usr/bin/plutil -convert json -o -`의 bounded output 및
  strict signature·stapler·Gatekeeper command의 성공 receipt를 받아 manifest의 `Signing`과 제품 관측을 직접 만든다.
  codesign detail은 `Identifier`와 `TeamIdentifier`를 exact 1회 요구하고 `not set`·빈 값·제어문자를 거부한다. designated
  requirement는 exact 1개 `designated =>` line이어야 하며 Apple anchor와 같은 team OU를 포함해야 한다. 따옴표 밖의
  disjunction·negation은 필수 절을 우회할 수 있으므로 거부하고, canonical line의 SHA-256만 manifest에 보존한다. plist JSON은
  exact `CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion`을
  consumed-field duplicate/missing/type/cap 관점에서 fail-close하고 `product_identity.bundle_id`·`bundle_version`이 소유하는
  product identity, codesign identifier 및 release version과 교차검증한다.
  architecture output은 `arm64 x86_64` exact 정렬 집합만 허용한다. strict signature, app/DMG stapler validate와 DMG
  Gatekeeper assessment receipt가 모두 true일 때만 `notarization=accepted`, `stapled=true`를 만든다. 이 component는 이미
  bounded capture된 bytes와 command success receipt의 의미를 검증할 뿐, pathname 권위·DMG no-follow 추출·실제 command argv
  배선이나 receipt 진위를 대신하지 않는다. 성공 경로의 allocation fail-index는 전수 unwind한다.

  Apple command transport는 `release_adapter_apple_transport.zig` 한 곳이 닫힌 command vocabulary와 argv를 소유한다.
  caller는 executable이나 임의 option을 넘기지 않고, DMG 추출 경계가 먼저 만든 absolute app bundle·Info.plist·제품
  executable·DMG pathname만 넘긴다. transport는 `/usr/bin/plutil -convert json -o - <Info.plist>`,
  `/usr/bin/codesign -d --verbose=4 <app>`, `/usr/bin/codesign -d -r- --verbose=0 <app>`,
  `/usr/bin/lipo -archs <executable>`의 bounded capture와
  `/usr/bin/codesign --verify --strict --deep <app>`, `/usr/bin/xcrun stapler validate <app|dmg>`,
  `/usr/sbin/spctl -a -t open --context context:primary-signature -v <dmg>`의 exit-0 receipt만 만든다. 모든 child는
  inherited environment 없이 실행하며 stdin `/dev/null`, monotonic deadline, output cap, process-group kill/reap을
  `bounded_process.zig`에서 공유한다. capture와 receipt는 모두 성공해야만 `release_adapter_apple_product.Captures`로
  조립되며 중간 실패는 부분 관측을 반환하지 않는다. focused gate
  `test-session-host-release-adapter-apple-transport`는 exact executable/argv/empty environment, command별 capture,
  cap·timeout·child failure와 receipt all-or-nothing을 Debug·ReleaseFast에서 검증한다. pathname의 no-follow authority와
  DMG mount/extraction은 별도 후속 경계이므로 transport 성공만으로 provenance를 주장하지 않는다.

  DMG pathname 권위와 추출 수명은 `release_adapter_dmg_authority.zig` 한 곳이 소유한다. caller는 absolute candidate
  DMG와 absolute absent work-directory, manifest가 선언한 expected size/SHA-256만 넘긴다. authority는
  [GitHub Release의 단일 asset 한도](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)보다
  작은 값만 받는 `max_dmg_bytes`를 소유한다. work-directory를 exclusive 0700으로 만들고, candidate의
  모든 pathname component를 `openat(O_NOFOLLOW)`로 내려가 연 regular fd에서 0600 `candidate.dmg` 복사본을
  bounded streaming write·`fsync`한다. 복사 전후 source fd의 device/inode/type/size/time identity와 복사본의 size/SHA-256을
  대조하므로 `hdiutil`이 caller pathname을 다시 열지 않는다. 원본 DMG와 private 복사본이 완전히 결속되기 전에는 mount
  command를 실행하지 않는다.

  authority는 private `mount` leaf를 0700으로 만든 뒤 `/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen
  -mountpoint <mount> <private-candidate>`만 clean environment·bounded output·deadline으로 실행한다. 성공 뒤 mountpoint의
  `statfs`가 read-only이고 mount source가 `/dev/disk*`인 exact filesystem identity와 mount root device/inode를 보존한다.
  제품 경로는 exact `Maru.app/Contents/Info.plist`와 `Maru.app/Contents/MacOS/maru-macos-app`뿐이며, mount root부터 각
  component를 `openat(O_NOFOLLOW)`로 순회해 directory/regular-file type과 같은 mounted filesystem을 확인한다. symlink,
  hardlink executable, extra path 선택, writable mount, mount/source identity drift는 fail-close한다. Apple transport 전후에
  mount filesystem·root·Info.plist·executable identity를 다시 확인하며, 어느 command가 실패해도 부분 `Captures`를
  반환하지 않는다.

  성공·실패·timeout 모두 `/usr/bin/hdiutil detach <captured-device>`를 먼저 시도하고, detach 뒤 같은 filesystem이 더는
  private mountpoint에 결속되지 않았음을 확인한 다음 자신이 만든 empty mount/work-directory만 exact device/inode로
  제거한다. attach가 command failure를 반환했더라도 mountpoint가 실제 mount가 됐으면 같은 정리를 수행한다. detach 또는
  directory 정리가 실패하면 앞선 검증 성공을 반환하지 않는다. focused gate
  `test-session-host-release-adapter-dmg-authority`는 fake runner로 exact argv·clean environment·성공/실패 cleanup과
  pre/post identity drift를 Debug·ReleaseFast에서 고정하고, macOS actual-DMG E2E로 read-only mount, fixed product
  no-follow traversal, device-identity detach와 residue 0을 검증한다. 이 경계만으로 GitHub 관측·manifest·attestation·evidence
  aggregate의 최종 조립이나 release workflow 배선을 주장하지 않는다.

  signing job은 GitHub Environment exact `release`를 사용한다. adapter는 caller가 설정한 `environment=release` 문자열을
  신뢰하지 않고, 현재 run/job의 deployment가 그 environment에 결속됐으며 repository의 protection policy가 적용됐음을 GitHub
  API에서 확인해 `PublicationObservation.protected_environment`를 만든다. 이 증거가 없거나 API가 불완전하면 fail-close한다.
  Environment REST 응답의 component 의미 해석은 `release_adapter_github_environment.zig`가 소유한다. exact nonzero
  environment ID와 `name=release`, `protection_rules[].{id,type}` 및 rule별 payload, nullable `deployment_branch_policy`의
  `protected_branches`/`custom_branch_policies`와 `can_admins_bypass=false`를 typed observation으로 보존한다. 관리자 bypass가
  허용되거나 필드가 빠진 응답은 보호 통과 증거로 사용할 수 없다. 알려진 rule type은
  `required_reviewers|wait_timer|branch_policy`로 닫고, endpoint가 나중에 추가한 rule type은 additive field처럼 허용하되
  보호 증거로 세지 않는다. consumed field의 missing·duplicate·wrong wire type, zero/duplicate rule ID, 같은 알려진 rule의
  중복, 1~43,200분 밖 wait timer, 1~6명이 아니거나 `User|Team`/nonzero ID가 아닌 reviewer, known rule에 맞지 않는
  payload, `branch_policy` rule과 nullable policy object의 불일치 및 두 branch-policy bool이 exact-one이 아닌 경우를 거부한다.
  이 parser는 환경에 구성된 보호 사실만 증명하며
  현재 workflow run/job이 그 환경의 deployment를 통과했다는 증거가 아니다. 후속 adapter가 current run/job deployment와 이
  observation을 결속하기 전에는 `PublicationObservation.protected_environment=true`를 만들 수 없다. 근거는 GitHub REST API의
  [Deployment environments schema](https://docs.github.com/en/rest/deployments/environments)다.

  current job과 environment deployment의 결속은 GitHub REST의 attempt-scoped jobs, deployments, deployment statuses 세 응답을
  한 판정자가 함께 해석한다. jobs 응답에서는 이미 검증한 `run_id`와 `run_attempt` 아래 exact release signing job name이 하나뿐이고,
  그 job의 nonzero ID, exact source SHA, `status=in_progress`, `conclusion=null`, canonical GitHub job URL을 보존해야 한다. deployments
  응답의 후보는 exact repository URL, source SHA, `ref=<canonical-tag>`, `task=deploy`,
  `environment=original_environment=release`, nonzero deployment ID, `performed_via_github_app.slug=github-actions`에 결속한다.
  각 후보의 statuses 응답은 pagination이 완결된 전체 이력이어야 하고, 각 status의 canonical status URL·deployment URL·repository URL이
  그 후보와 exact하게 결속돼야 한다. deployment status는 공식 REST vocabulary인
  `error|failure|inactive|in_progress|queued|pending|success`만 인정한다. 현재 job URL과 exact environment를 공유하는
  `pending`과 exact-one `in_progress`를 포함하고 attempt-scoped job 응답도 동시에 `in_progress/conclusion=null`이어야 한다.
  REST 문서가 status 배열 정렬을 보장하지 않으므로 배열 위치나 비공식 `waiting` 값을 최신성·보호 근거로 사용하지 않는다.
  같은 job URL에 결속되는 deployment가 0개 또는
  2개 이상이면 replay/ambiguity로 거부한다. deployment creator는 workflow를 시작한 사용자일 수 있으므로 bot identity의 근거로
  사용하지 않고, status의 optional app도 보호 증거로 승격하지 않는다. 공식 vocabulary 밖 unknown status는 미래 의미를
  보호 권위로 오인하지 않도록 응답 전체를 fail-close한다.

  최종 보호 판정은 위 exact-one deployment 결속과 environment observation의 recognized protection rule 하나 이상을 모두 요구한다.
  현재 environment 설정을 다시 읽은 사실만으로 과거 job에 정책이 적용됐다고 주장하지 않으며, bypass 불가 설정과 같은 job URL의
  공식 `pending`→현재 `in_progress` 관측으로 실제 protection 대기를 교차검증한다. 반대로 pending-deployments endpoint는 보호 규칙을 통과한 뒤 job 안에서 더는 현재
  deployment를 반환하지 않으므로 사후 증거로 쓰지 않는다. API bytes parser와 resolver는 transport authority, endpoint URL,
  pagination 완결성, 현재 실행 중인 executable 자체를 증명하지 않는다. bounded GitHub API transport와 release workflow의
  `environment: release` 배선이 추가되고 repository에 실제 recognized protection이 설정되기 전에는
  `PublicationObservation.protected_environment=true`를 만들 수 없다. 근거는 GitHub REST API의
  [workflow jobs](https://docs.github.com/en/rest/actions/workflow-jobs),
  [deployments와 statuses](https://docs.github.com/en/rest/deployments/deployments)다.

  bounded GitHub API transport의 OS 중립 요청 SSOT는
  `release_adapter_github_transport.zig`다. 호출자는 임의 URL, HTTP method, header, `jq` 식을 문자열로 넘기지 않고
  `repository`, `workflow_run`, `draft_releases`, `published_release`, `tag_ref`, `annotated_tag`, `environment`,
  `attempt_jobs`, `deployments`, `deployment_statuses`의 닫힌 request kind와 앞 단계에서 검증한 typed ID/tag/SHA만 넘긴다.
  각 kind는 exact `repos/ohah/maru/...` REST endpoint, `GET`, `github.com`,
  `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`과 고정 query를 만든다. 숫자는 canonical
  nonzero decimal, tag와 SHA는 공통 identity parser를 다시 통과해야 하며 slash, `..`, `%`, query/fragment를 caller가
  주입할 자리는 없다. `draft_releases`는 tag-name endpoint가 아니라 exact repository release 목록 collection이다.
  collection endpoint는 `per_page=100`과 `gh api --paginate --slurp`를 항상 함께 쓰며, `gh`가
  `--slurp`와 `--jq` 동시 사용을 거부하므로 jq/template을 넘기지 않는다. 대신 transport가 bounded outer page array를
  파싱해 array page는 한 array로, jobs page는 모든 page의 동일 `total_count`가 실제 합친 `jobs` 개수와도 정확히 같은
  object 하나로 직렬화한다. transport는 합쳐진 root가
  `release_adapter_github_json.max_response_bytes` 이하인 완전한 JSON 하나일 때만 반환하고, endpoint별 component parser가
  기존 `max_collection_entries=100`을 적용한다. 따라서 pagination을 생략한 첫 page, 101번째 항목, 두 root/trailing bytes는
  component 권위로 승격되지 않는다. transport가 JSON 의미와 collection 상한을 두 번째로 해석하지 않는다.

  macOS 실행 leaf는 caller PATH나 shell을 쓰지 않고 workflow가 넘긴 absolute GitHub CLI executable과 transport가 만든
  fixed argv만 `bounded_process.zig`에 준다. 인증은 GitHub Actions가 step의 `GH_TOKEN`으로 제공하며 token은 option/header/argv,
  stdout/stderr, summary에 넣지 않는다. child 환경은 inherited environment가 아니라 exact `GH_TOKEN`과
  `GH_PROMPT_DISABLED=1`만으로 다시 만든다. JSON 권위 입력은 bounded stdout만이며 stderr는 `/dev/null`로 분리한다. 둘을
  합치면 성공한 `gh`의 경고 한 줄도 JSON에 섞이고, 반대로 진단 text를 REST bytes로 오인할 수 있기 때문이다. stdin
  `/dev/null`, positive monotonic deadline, process-group kill/reap은 기존 bounded process 규율을 재사용한다. 실행 결과는
  executor에 제공한 bounded stdout 버퍼에서 빌린 slice만 인정하며 외부 storage를 capture로 승격하지 않는다.
  missing/empty/control/NUL/4 KiB 초과 token, relative executable, unknown request,
  nonzero exit, timeout, output cap은 terminal failure다. transport 단독 성공은 고정 호출이 낸 REST-shaped bytes를 bounded하게
  획득했다는 뜻이며, caller가 넘긴 executable pathname의 공급망 provenance나 release workflow 배선을 혼자 증명하지 않는다.
  두 권위가 후속 배선에서 함께 검증된 뒤에만 이 bytes를 authenticated GitHub observation으로 승격한다. `GH_TOKEN` 환경 전달과
  pagination flag의 근거는 GitHub의
  [workflow에서 GitHub CLI 사용](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-github-cli)과
  [`gh api` 명세](https://cli.github.com/manual/gh_api)다.
  focused gate `test-session-host-release-adapter-github-transport`는 exact argv와 clean environment, 모든 request kind,
  pagination flags/직접 flattening과 count 완결성, `--slurp`+`--jq` 금지, token 비노출, malformed identity,
  supplied-buffer provenance, cap/timeout/child failure를
  Debug·ReleaseFast에서 검증한다.

  artifact attestation의 command/semantic 권위는
  `release_adapter_github_attestation.zig` 한 곳이 소유한다. command는 caller가 flag나 predicate를 고르지 못하게
  `/absolute/gh attestation verify <absolute-artifact>`와 exact `--repo ohah/maru`,
  `--signer-workflow ohah/maru/.github/workflows/release.yml`, `--signer-digest <source commit>`,
  `--source-digest <source commit>`, `--source-ref refs/tags/<canonical tag>`, `--deny-self-hosted-runners`,
  `--predicate-type https://slsa.dev/provenance/v1`, `--format json`을 고정한다. 실행 leaf는 REST transport와 같은
  inherited-environment 0, exact `GH_TOKEN`/`GH_PROMPT_DISABLED=1`, stdin `/dev/null`, bounded stdout, positive monotonic
  deadline과 process-group kill/reap을 사용한다. stdout slice는 caller가 제공한 bounded buffer 안에서 빌린 값만
  인정한다.

  성공 JSON은 `gh attestation verify --format json`의 exact-one result array여야 한다. semantic authority는
  `verificationResult.signature.certificate`의 GitHub OIDC issuer, exact workflow SAN/build signer/config URI,
  `githubWorkflowTrigger=push`, workflow SHA/repository/ref, `runnerEnvironment=github-hosted`, source repository
  URI/digest/ref/numeric repository ID, public visibility와
  `runInvocationURI=https://github.com/ohah/maru/actions/runs/<run_id>/attempts/<run_attempt>`를 trusted context에
  exact 결속한다. 이 값들은 verified certificate summary에서만 권위로 사용한다. statement는 exact in-toto v1,
  SLSA provenance v1, subject 이름/SHA-256 exact-one과 certificate/context에 맞는 build definition·run invocation을
  요구하지만 workflow가 쓸 수 있는 predicate field를 독립 권위로 승격하지 않는다. verified timestamp는 non-empty여야
  한다. duplicate/missing/wrong type/additional verified result, 다른 run/attempt·workflow/ref/repository/runner,
  subject 추가·교환과 malformed/trailing/cap 초과 JSON은 terminal failure다.

  이 계약은 GitHub CLI 공식 `attestation verify`가 certificate extensions에 적용하는 repository/source/signer/runner
  policy와 JSON exporter의 verified certificate summary를 함께 사용한다. focused gate
  `test-session-host-release-adapter-github-attestation`은 exact argv·clean environment·buffer provenance와 정상
  certificate/statement, 모든 identity/run/subject mismatch, duplicate/malformed/cap/timeout/child failure를
  Debug·ReleaseFast에서 검증한다. 이 component만으로 checkout 전 CLI pin/revalidation, release attestation,
  predecessor asset download 또는 최종 executable/workflow 배선을 완료했다고 주장하지 않는다.

  post-publish release attestation의 command/semantic 권위는
  `release_adapter_github_release_attestation.zig` 한 곳이 소유한다. release 전체 검증은
  `/absolute/gh release verify <canonical-tag> --repo ohah/maru --format json`, 각 선행 no-follow 관측에 결속할 local asset 검증은
  `/absolute/gh release verify-asset <canonical-tag> <absolute-asset> --repo ohah/maru --format json`의 exact argv만 허용한다.
  latest release 추론, `--jq`/`--template`, custom trusted root와 caller option은 없다. child는 artifact attestation과 같은
  clean `GH_TOKEN`/`GH_PROMPT_DISABLED=1`, bounded stdout, positive monotonic deadline, process-group kill/reap을 사용하며
  반환 slice는 supplied buffer 안에서만 빌린다. asset pathname은 absolute이고 basename이 expected asset name과 같아야 한다.

  `--format json`의 exact object는 GitHub release attestation verifier가 검증한 certificate SAN
  `https://dotcom.releases.github.com`, non-empty verified timestamp와 in-toto v1 statement를 가져야 한다. statement는
  `predicateType=https://in-toto.io/attestation/release/v0.1`, exact repository/repository ID/release ID/tag와
  `pkg:github/ohah/maru@<tag>` purl을 결속한다. subject는 purl subject exact 1개, manifest가 열거한 세 asset과
  그 canonical manifest 파일 자체까지 공개 시점의 attached artifact 네 개 name/SHA-256 exact set이어야 하며
  missing/duplicate/additional asset을 거부한다. 각 `verify-asset` 결과도 같은 release statement와 자기 local
  basename/SHA subject를 모두 포함해야 한다. release predicate의 `ownerId`는 canonical nonzero인지 검사하되,
  repository string과 immutable numeric repository ID가 이미 결속되므로 별도 owner 권위로 승격하지 않는다.

  release purl subject의 SHA-1은 **tag ref digest**이지 annotated tag를 peel한 최종 source commit이라고 가정하지 않는다.
  이 component는 verified `tag_ref_sha`를 반환하고, 후속 executable composition만 기존
  `release_adapter_git_resolver.zig`의 exact tag chain이 manifest source commit으로 수렴한 결과와 함께
  `ReleaseAttestation.source_commit`을 만든다. lightweight tag에서는 두 값이 같을 수 있지만 그 우연을 계약으로 쓰지 않는다.
  focused gate `test-session-host-release-adapter-github-release-attestation`은 release/asset exact argv, clean environment,
  release identity와 purl/tag-ref/manifest 포함 attached artifact set, local asset 선택, malformed/duplicate/cap/timeout/child failure를
  Debug·ReleaseFast에서 검증한다. 이 gate만으로 CLI pin/revalidation, predecessor download, git resolver composition 또는
  final workflow 배선을 완료했다고 주장하지 않는다.

  predecessor asset 다운로드의 command/filesystem 권위는 `release_adapter_github_download.zig`가 소유한다. caller가
  destination filename이나 glob을 따로 고르지 못하게 canonical manifest의 세 asset role을 exact once 받아 role 순서로
  처리한다. 각 command는 `/absolute/gh release download <canonical-tag> --repo ohah/maru --pattern <escaped-exact-name>
  --output -`만 사용한다. pattern은 macOS/Go `filepath.Match`의 `\\`, `*`, `?`, `[`를 각각 escape해 literal asset name
  하나만 선택하며 latest 추론, `--dir`, `--clobber`, `--skip-existing`, archive와 caller option은 금지한다. stdout은 binary
  asset bytes이고 stderr는 `/dev/null`이다. child environment, deadline과 process-group kill/reap은 다른 GitHub leaf와 같은
  exact `GH_TOKEN`/`GH_PROMPT_DISABLED=1` bounded process 규율을 쓴다.

  downloader는 absolute absent work-directory를 parent `openat(O_NOFOLLOW)` 아래 0700 exact once로 만들고 final-address
  handle로 parent/work directory의 device/inode를 소유한다. 각 expected asset leaf도 work directory fd에
  `O_CREAT|O_EXCL|O_NOFOLLOW` 0600으로 먼저 만들며 manifest size만큼 macOS `F_PREALLOCATE`와 `ftruncate`를 모두 성공시킨다.
  그 exact-size shared mapping만 bounded child stdout buffer로 제공한다. capture가 mapping 밖을 가리키거나 byte count가
  manifest size와 다르고, EOF/exit 0가 없거나 SHA-256이 다르면 terminal failure다. 성공은 `msync`/file `fsync`, post-write
  fstat identity/type/size/link-count exact 1, 0400 mode와 work-directory `fsync`까지 끝난 뒤에만 게시한다. 이 방식은 `gh --dir`의
  `stat`→`O_TRUNC` pathname 재열기와 symlink 경합을 권위 경계에서 제거하고, 2 GiB급 asset을 heap buffer로 만들지 않는다.

  어느 asset에서든 실패하면 같은 open directory fd와 기록한 inode로 자신이 만든 leaf만 제거하고 directory `fsync` 뒤
  exact parent/leaf identity가 여전히 맞을 때 empty work-directory를 제거한다. cleanup을 확정하지 못하면 원래 오류를 성공이나
  clean rollback으로 바꾸지 않고 terminal cleanup failure로 올린다. 성공 결과는 세 asset의 absolute path, device/inode,
  size/SHA-256을 가진 move-only `DownloadedSet`이며 후속 release `verify-asset`과 manifest observation이 소비한 뒤 exact cleanup한다.
  focused gate `test-session-host-release-adapter-github-download`은 glob metacharacter literalization, exact argv/clean environment,
  실제 exclusive work-directory와 mapped write/path·identity·digest 결과, short/long/digest mismatch, symlink·existing
  work-directory, timeout/child failure와 성공·실패 residue 0을 Debug·ReleaseFast에서 검증한다. 이 gate만으로
  CLI pin/revalidation, release attestation 호출, git resolver나 final workflow composition을 완료했다고 주장하지 않는다.

  predecessor asset composition은 인증된 A manifest만 세 asset의 allocation 권위로 받아 기존 downloader, release
  attestation verifier와 git resolver를 조립한다. composition은 CLI pathname을 각 download·release verify·세
  verify-asset 호출 직전에 재검증하고, downloader가 게시한 exact path/device/inode/size/SHA-256과 owner-only work-directory를
  각 외부 검증 전후에 다시 관측한다. pathname 교체, hard link 추가, mode 변경, 내용 mutation, work-directory rename/replacement는
  검증 결과가 성공이어도 terminal failure다. release 전체 statement와 세 verify-asset statement는 모두 manifest의 immutable
  release ID/tag와 exact asset set에 결속해야 한다.

  release purl의 SHA-1은 첫 tag ref 관측의 target object SHA와 exact 일치해야 하며 annotated tag를 peel한 source commit으로
  해석하지 않는다. 기존 bounded git resolver만 ref/tag observation chain을 소비해 manifest의 source commit으로 수렴시킨다.
  모든 호출·재관측·resolver 수렴이 끝난 뒤에만 final-address move-only `AuthenticatedPredecessorAssets`를 게시한다. 이 owner는
  인증된 세 local asset과 source commit을 조회하고 exact cleanup할 유일한 권위다. 어느 단계에서든 실패하면 이미 만든
  `DownloadedSet`을 exact cleanup하며, cleanup을 확정하지 못하면 원래 검증 오류보다 cleanup failure를 우선한다. focused gate
  `test-session-host-release-adapter-github-predecessor-assets`는 lightweight/annotated tag 성공, exact 호출 순서와 CLI/file
  revalidation, release/asset/ref/commit mismatch, pathname·inode·mode·digest drift, copied owner, child/OOM/depth/cycle failure의
  publication 0과 residue 0을 Debug·ReleaseFast에서 검증한다. 이 gate는 checkout 전 CLI capture나 release workflow wiring,
  Apple product 판정과 최종 U5 frozen release E2E를 대신하지 않는다.

  GitHub CLI executable 권위는 **공식 GitHub Release CI에만** 적용한다. 로컬 빌드·로컬 업그레이드와 앱 인증서 기반
  session-host upgrade 경로에는 이 계약을 요구하지 않는다. trusted release job은 repository checkout보다 먼저 GitHub가
  제공한 초기 PATH에서 `gh`의 symlink-free canonical absolute path와 lowercase SHA-256을 한 번 캡처해 immutable step output으로
  넘긴다. checkout 뒤의 repository 파일이나 PATH 재탐색으로 executable을 선택하지 않는다. adapter는 두 CLI option을 모든 phase에서
  필수로 받고, `GITHUB_WORKFLOW_SHA`가 검증된 source commit과 같으며 `RUNNER_ENVIRONMENT=github-hosted`, `RUNNER_OS=macOS`,
  `RUNNER_ARCH=ARM64`인 exact runner authority만 허용한다. path는 absolute·canonical·symlink-free regular executable이어야 하고
  expected SHA-256과 같은 열린 파일의 device/inode/size/digest를 기록한다. transport에 넘기기 직전 pathname을 다시 열어 같은
  identity와 digest인지 검사하며 교체·mutation·symlink를 fail-close한다. 이 revalidation은 fresh GitHub-hosted runner의 trusted
  workflow 경계 안에서만 권위가 있다. self-hosted runner나 임의 로컬 환경을 GitHub service provenance로 승격하지 않는다.

  focused gate `test-session-host-release-adapter-github-cli-authority`는 OS 중립 runner observation과 CLI/path/digest 계약,
  macOS 실제 filesystem의 symlink·교체·내용 변경 fail-close를 Debug·ReleaseFast에서 검증한다. component 성공만으로 protected
  workflow가 checkout 전 capture를 실제 수행했거나 transport 호출과 결합됐다고 주장하지 않는다. 그 결합은 release workflow
  wiring gate가 별도로 소유한다.

  release workflow의 checkout 전 CLI capture 계약은 `.github/workflows/release.yml`과
  `tests/release_workflow/authority_capture.zig`가 함께 소유한다(§2m.110에서 셸 스크립트를 Zig로 옮겼다 — 재는 것은 그대로다). release job의 첫 repository-content 접근보다 앞선
  `Capture trusted GitHub CLI before checkout` step은 초기 runner PATH에서 `gh`를 exact once 찾고, symlink를 해소한 canonical
  absolute path가 regular executable인지 확인한 뒤 lowercase SHA-256을 계산한다. 두 값은 같은 step의 immutable output으로만
  게시하며 `GITHUB_ENV`, repository pathname 또는 checkout 뒤 PATH 재탐색으로 넘기지 않는다. job은 exact
  `environment: release`, `runs-on: macos-15`를 사용하고 checkout은 이 capture 뒤에만 온다. focused gate
  `check-session-host-release-workflow`는 trigger가 tag-only인지, 모든 Action이 commit SHA에 고정됐는지와 함께 capture→checkout
  순서, exact command/output vocabulary, environment와 runner를 실제 workflow bytes에서 검증한다. 이 gate는 아직 captured output을
  validator argv에 소비하거나 manifest/evidence를 만들고 release를 publish하는 전체 workflow 배선을 완료했다고 주장하지 않는다.

  publication transcript의 `candidate_attested`는 draft보다 먼저 성립한다. 이 권위는
  `release_adapter_candidate_attestation.zig`의 final-address move-only `CandidateAttestation`이 단독 소유한다. 입력은 trusted tag
  `Context`, universal DMG/frozen executable의 absolute pathname, checkout 전 고정한 GitHub CLI, validated token과 같은 release
  phase `Deadline`뿐이며 draft/release ID나 caller-provided size/SHA/subject는 받지 않는다. exact basename은 tag version에서 유도하고
  두 file을 no-follow held fd와 parent-directory authority로 pin한 뒤 distinct inode, nonzero 공통 asset cap, frozen execute bit를
  확인한다.

  attestation은 canonical DMG→frozen 순서다. 각 child 전에 같은 CLI와 held file을 재검증하고 fresh remaining만 전달하며 verifier의
  repository/tag/source/build와 subject basename/SHA를 trusted context와 pinned file에서 직접 유도한다. 각 child 뒤 file을 다시
  revalidate하고 두 owned observation을 얻은 뒤에도 같은 deadline을 마지막으로 확인해야만 owner를 게시한다. 어느 CLI/file/context/
  subject drift, timeout, child/OOM 실패에서도 partial observation을 역순 해제하고 fd authority를 닫아 publication 0으로 끝낸다.
  성공 owner는 두 held file과 exact attestation observations를 보존하며 후속 draft-bound candidate owner는 raw pathname을 다시 pin하지
  않고 이 owner를 revalidate해 소비한다. focused gate `test-session-host-release-adapter-candidate-attestation`은 actual filesystem과
  injected authority/verifier로 exact order/deadline, draft 입력 0, copied/pre-owned owner, alias/mutation, final expiry와 allocation unwind를
  Debug·ReleaseFast에서 검증한다. 이 gate만으로 draft 생성, Apple product, evidence/manifest authoring이나 workflow/U5 E2E를 완료했다고
  주장하지 않는다.

  release executable bootstrap의 단일 소유자는
  `src/platform/macos/session_host/release_adapter_executable_bootstrap.zig`다. bootstrap은 기존
  `release_adapter_contract.parseArgs`로 command를 먼저 닫고, 기존 `release_adapter_environment`의 exact process context와
  `release_adapter_github_cli_authority`의 runner observation을 읽는다. command의 repository와 tag는 context의 typed
  repository owner/name과 protected tag에 exact 교차결속하며, 불일치하면 CLI pathname을 열기 전에 실패한다. 그 뒤에만
  command가 요구한 checkout 전 canonical absolute `gh` path와 lowercase SHA-256을 bounded NUL-terminated storage로 복사해
  pin한다. 성공 결과는 copy를 거부하는 final-address owner로만 게시하며 parsed phase command에서는 CLI path/digest를 제거한다.
  후속 phase는 owner 검증 view가 보존한 exact CLI path만 재검증·실행한다. bootstrap은 token을 읽거나 GitHub API를 호출하거나 manifest/local asset/work-dir/
  summary pathname을 열지 않는다. 따라서 parse/context/runner/cross-binding 실패는 filesystem observation 0이고 CLI pin 실패도
  phase orchestration이나 output publication으로 진행하지 않는다.

  focused gate `test-session-host-release-adapter-executable-bootstrap`은 기존 parser를 통과한 두 command의 exact
  context/runner/CLI 결속, context보다 먼저 CLI를 열지 않는 ordering, repository/tag drift, foreign/self-hosted runner,
  non-executable·digest mismatch와 bounded path copy를 Debug·ReleaseFast actual filesystem에서 검증한다. product entrypoint가
  process environment를 읽도록 컴파일되는 것도 고정하지만 로컬 셸을 trusted runner oracle로 취급하지 않는다. 이 gate는
  GitHub API token capture, 두 phase의 전체 owner orchestration, workflow의 checkout 전 CLI capture, GitHub Release publication
  또는 frozen U5 제품 E2E를 대신하지 않는다.

  release executable의 token process leaf 단일 소유자는
  `src/platform/macos/session_host/release_adapter_token_environment.zig`다. leaf는 process environment를 열거하거나 workflow
  shell이 바꾼 별칭을 받지 않고 exact `GH_TOKEN` 하나만 조회한다. 값의 empty/control/NUL/4 KiB 상한은 새 parser로 복제하지
  않고 기존 `release_adapter_github_transport.validateToken`을 그대로 호출해 transport와 같은 정책으로 fail-close한다.
  성공 값은 process environment에서 빌린 slice이며 heap·argv·header·diagnostic·summary storage로 복사하지 않는다. executable은
  token view가 살아 있는 동안 `setenv`/`unsetenv`를 호출하지 않고, 후속 phase orchestration만 bootstrap의 pinned CLI와 이
  validated token을 함께 소비한다. 후속 phase orchestration은 missing/invalid token을 CLI revalidation,
  GitHub API/attestation child, local asset open, work-directory 또는 summary publication보다 먼저 검사해야 한다.

  focused gate `test-session-host-release-adapter-token-environment`는 exact `GH_TOKEN` lookup 1회, missing/empty/control/NUL/cap+1,
  기존 validator delegation과 borrowed-byte provenance를 Debug·ReleaseFast에서 검증한다. product leaf는 local shell을 trusted
  release oracle로 삼지 않고 compile만 고정한다. token 내용을 실패 진단에 넣지 않으며 gate fixture도 실제 credential을 읽거나
  출력하지 않는다. 이 component는 두 phase 전체 owner ordering, workflow permission, checkout 전 CLI capture, GitHub Release
  publication 또는 frozen U5 제품 E2E를 대신하지 않는다.

  release executable의 cross-component 시간 권위 단일 소유자는
  `src/platform/macos/session_host/release_adapter_deadline.zig`의 final-address `Deadline`이다. 전체 phase orchestration은
  token 검증 직후 positive budget과 `CLOCK_MONOTONIC` 관측 하나로 absolute expiry를 exact once 만들고, 모든 GitHub API·artifact
  attestation·Apple product·compatibility child 직전에 같은 owner의 `remaining`만 받는다. 하위 composition이 전달받은 remaining
  budget으로 새 만료 시각을 만들지 않도록 후속 `...Until` entrypoint는 이 owner pointer를 직접 소비한다. clock rollback,
  signed overflow, 만료, copied/pre-owned owner는 외부 command 전에 fail-close하며 deadline을 갱신·연장하는 API는 제공하지 않는다.

  focused gate `test-session-host-release-adapter-deadline`은 positive start, monotonic non-increasing remaining, exact expiry,
  rollback·overflow·zero/negative budget, copied/pre-owned owner와 real monotonic leaf compile을 Debug·ReleaseFast에서 검증한다.
  이 leaf만으로 하위 composition의 `...Until` 이관, 두 phase 전체 orchestration, workflow 배선 또는 frozen U5 제품 E2E를
  완료했다고 주장하지 않는다.

  첫 `...Until` 소비자는 `release_adapter_github_current_authority.zig`다. executable orchestration은 budget 기반 leaf 대신
  final-address `Deadline` pointer를 넘기며 repository, workflow run, environment, attempt jobs, deployments와 각 deployment
  status request의 CLI revalidation 전후에 같은 owner의 remaining을 조회하고 두 번째 값만 child budget으로 전달한다. request마다 시작 시각이나 expiry를 다시 만들지 않고, 만료·copied
  deadline이면 CLI revalidation과 HTTP child 전에 실패한다. 기존 budget entrypoint는 독립 component 호출과 기존 gate 호환을
  위해 남지만 전체 phase owner는 호출하지 않는다. focused current-authority gate는 injected shared deadline의 exact request별
  감소, 중간 만료 시 후속 request 0과 publication 0을 Debug·ReleaseFast에서 추가 검증한다. current release draft/tag-chain,
  manifest/asset attestation, Apple product와 compatibility의 `...Until` 이관은 후속 범위다.

  release evidence의 canonical bytes는 OS 중립
  `src/platform/macos/session_host/release_evidence.zig` 한 곳이 소유한다. schema는 exact
  `maru.session-host-release-evidence.v1`이고 profile은 `baseline_a | upgrade_b`의 닫힌 union이다. G3의
  `default=false→true` migration evidence는 이 schema에 optional field로 섞지 않고
  [별도 이니셔티브](persistent-session-host.md#session-default-g3-frozen-release-migration)가 소유한다. 따라서 U5 frozen
  release 호환성 증거를 아직 승인되지 않은 default 전환에 종속시키지 않고, 나중의 G3 release는 U5 `upgrade_b` evidence와
  자기 default-migration evidence를 모두 요구한다.

  evidence root key는 writer가 아래 표 순서로 쓰며 parser는 모든 scope의 duplicate·unknown·missing key, trailing value,
  잘못된 UTF-8·wire type·정수 overflow와 noncanonical writer bytes를 거부한다. `result`는 caller 입력 bool이 아니라 모든
  profile 불변식이 성립한 성공 writer만 exact `passed`로 만든다.

  | scope | 필수 필드 | 불변식 |
  | --- | --- | --- |
  | root | `schema`, `profile`, `role`, `test_uuid`, `repository`, `release`, `source`, `build`, `candidate`, `gates`, `result` | `baseline_a↔role=a`, `upgrade_b↔role=b`; B만 `predecessor` 추가 |
  | `test_uuid` | canonical lowercase RFC 4122 UUID v4 string | trusted run이 candidate attestation과 draft 생성 뒤 한 번 만들고 모든 gate에 전달하는 correlation일 뿐 권위가 아님 |
  | `repository` | `id`, `owner`, `name` | manifest 및 GitHub API observation과 exact 일치 |
  | `release` | `id`, `tag`, `version` | 이미 만든 exact draft와 manifest release에 결속 |
  | `source` | `commit`, `tree` | manifest source와 exact 일치 |
  | `build` | `workflow_ref`, `run_id`, `run_attempt` | 현재 trusted tag run 및 aggregate attestation과 exact 일치 |
  | `candidate` | `dmg_sha256`, `executable_sha256` | manifest의 exact universal DMG와 frozen product executable asset에 결속 |
  | B 전용 `predecessor` | `release_id`, `tag`, `commit`, `manifest_sha256`, `dmg_sha256`, `executable_sha256` | published immutable A manifest/release/asset과 exact 일치; current/old swap 거부 |
  | A `gates` | `default_false_baseline`, `signed_app_quit_reattach` | 둘 다 같은 A candidate와 `test_uuid`를 관측하고 exact `passed` |
  | B `gates` | `signed_upgrade_one`, `signed_upgrade_near_max` | 둘 다 같은 A predecessor/B candidate와 `test_uuid`; runtime count는 각각 exact 1과 `max_runtime_count - 1` |
  | root `result` | string | exact `passed`; 어느 gate라도 누락·실패·교환·candidate mismatch면 aggregate publication 0 |

  gate 입력 leaf는 staging artifact일 뿐 durable authority나 별도 Release asset이 아니다. `release_evidence.zig`가 각 exact
  leaf schema를 직접 strict parse하고 필요한 typed 관측값을 `gates` nested object에 canonical하게 보존한다. leaf SHA만 남겨
  사라진 bytes를 나중에 검증할 수 없게 만들거나, raw leaf를 base64 scalar로 넣어 scalar cap을 우회하지 않는다. A의 두 gate는
  signed app bundle/DMG와 frozen executable 모두를 candidate에 결속한다. B의 두 gate는 현재
  `tests/session_host_signed_upgrade_e2e.zig`가 직접 내는 exact
  `maru.session-host-signed-upgrade-e2e.v2`의 PID/runtime/epoch/screen/input/reap 관측을 보존하고
  1-runtime과 near-max artifact를 바꿔 끼우지 못하게 runtime count와 runtime-set digest를 profile policy에서 검증한다.

  signed-upgrade 제품 E2E는 trusted release run이 만든 canonical lowercase RFC 4122 UUID v4를 명시 입력받는다. 하네스가
  UUID를 자체 생성하거나 pathname·환경변수에서 추론하지 않으며, 1-runtime과 near-max 실행은 같은 UUID를 각 canonical v2
  leaf의 `test_uuid`로 기록한다. leaf는 predecessor/candidate executable SHA-256, exact signer requirement digest와 제품 관측만
  포함하고 executable pathname·host/runtime 내부 식별자·duration을 release evidence로 승격하지 않는다. 실행 시작 시 stale
  output을 먼저 제거하고 UUID·서명·제품 검증 중 하나라도 실패하면 새 leaf를 게시하지 않는다. 이 leaf 생산은 두 executable의
  release 인접성, immutable predecessor provenance 또는 aggregate attestation을 독자적으로 승인하지 않는다.

  signed-app-quit 제품 E2E도 trusted release run이 만든 같은 형식의 UUID와 candidate DMG·frozen executable의 pathname을
  명시 입력받는다. 하네스는 시작 시 stale output을 제거하고, 두 candidate file을 no-follow로 열어 실행 전 SHA-256을 고정하며,
  DMG와 별도 frozen executable을 no-follow로 고정하고, 실행할 app executable이 frozen executable과 exact SHA-256 및 strict Apple
  designated requirement가 같은지 검증한 뒤 실제 AppKit Quit→재실행을 수행한다. app bundle의 deep signature·notarization과 DMG 안
  제품 결속은 앞선 candidate product authority가 소유하며 이 leaf가 중복 승인하지 않는다.
  재실행 전후 exact host/runtime/child PID, 기존 화면 marker, 재접속 뒤에만 발생시킨 PTY output marker와 GUI가 선택한 exact runtime을
  함께 관측한다. daemon reap과 자기 전용 host artifact 정리가 끝난 뒤에만 exact
  `maru.session-host-signed-app-quit-reattach.v1` leaf를 absent output에 mode `0600`으로 배타 게시한다. pathname·host/runtime 내부 ID,
  duration과 AppKit 진단용 summary는 release leaf에 넣지 않는다. 이 leaf는 candidate file의 GitHub attestation이나 draft release
  provenance를 독자적으로 승인하지 않으며, baseline aggregate owner가 같은 candidate authority에 다시 결속한다.

  default-false 제품 E2E는 trusted release run이 만든 같은 형식의 UUID와 candidate DMG·frozen executable pathname을
  명시 입력받는다. 하네스는 stale output을 먼저 제거하고 두 candidate file과 실행할 app executable을 signed-app-quit gate와
  같은 no-follow identity·SHA-256·strict Apple designated-requirement 경계로 고정한다. 테스트 전용의 비어 있는 격리 config root에서
  실제 app executable을 시작하고, Swift가 writer lease를 얻어 `maru_macos_session_config_bootstrap`을 성공시킨 직후 Zig bootstrap
  owner가 가진 typed snapshot을 ABI의 닫힌 관측값으로 읽는다. 성공 관측은 exact `value=false`,
  `SessionKeepAliveProvenance.absent`, `FileProvenance.missing`이어야 하며 환경변수나 caller가 준 bool을 결과로 승격하지 않는다.
  관측 전후 candidate identity와 signer가 그대로이고 direct child가 정상 종료한 뒤에만 exact
  `maru.session-host-default-false-baseline.v1` leaf를 absent output에 mode `0600`으로 배타 게시한다. leaf의 `resolved_default=false`,
  `explicit_override_present=false`, `signed_product=true`는 각각 이 제품 관측과 하네스의 실제 서명 검증에서만 유도한다. 격리 root는
  사용자 config 및 session-host registry와 달라야 하고 성공·실패 모두 자기 artifact만 정리한다. 이 leaf는 default-on 전환을
  승인하지 않으며, candidate의 GitHub attestation·DMG deep signature/notarization·draft release provenance도 독자적으로 승인하지 않는다.

  signed universal 빌드가 위 두 baseline gate에 넘기는 candidate pathname은 공증 전이나 architecture별 `zig-out/Maru.app`에서
  재구성하지 않는다. `tools/build-macos-universal-dmg.sh`가 app·DMG 공증과 staple 검증을 끝낸 바로 그 universal app을
  `dist/session-host-candidate-<version>/Maru.app`으로 복제하고, 그 app의 main executable bytes를 별도
  `maru-session-host-<version>` regular executable로 동결한다. 같은 디렉터리의 DMG 사본까지 임시 sibling에서 완성한 뒤 final
  directory를 배타 rename하며 기존 final·symlink는 실패한다. app 내부 main executable과 frozen executable의 exact byte equality를
  게시 직전과 final pathname에서 다시 확인한다. 이 보존 단계는 candidate bytes가 같은 trusted build에서 왔음을 유지할 뿐 signer,
  notarization, GitHub provenance 또는 release publication을 새로 승인하지 않는다.

  두 baseline 제품 gate는 이 보존 디렉터리의 `Maru.app` absolute pathname을 공통
  `-Dsession-host-signed-candidate-app` 입력으로 받는다. build 조립은 main executable과 bundled CLI pathname을 그 bundle 아래에서만
  유도하며 release gate를 위해 별도 `macos-app-bundle`을 다시 만들거나 checkout의 `web/dist`를 제품 환경에 주입하지 않는다.
  candidate app 입력이 없거나 상대경로이면 skip/fallback하지 않고 하네스의 absolute-path 검증에서 실패한다. 두 gate의 app executable,
  candidate DMG와 frozen executable은 기존 no-follow digest·strict signer 검증으로 같은 candidate에 결속되며, signed-app-quit의 bundled
  CLI도 같은 bundle에서만 온다. 이 경로 조립은 app bundle 자체의 provenance를 승인하지 않으며 앞선 candidate product authority와
  release workflow의 결속 책임을 유지한다.

  `test_uuid`는 replay 방지 권위가 아니다. replay 방지는 repository/release/source/build run-attempt, A/B DMG·executable
  digest와 aggregate artifact attestation을 함께 교차검증해 닫는다. OS 중립 core는 leaf bytes를 strict parse해 canonical
  aggregate bytes만 반환하고 filesystem을 열거나 publication 성공을 주장하지 않는다. 후속 executable adapter가 기존
  `release_adapter_files.zig`의 no-follow input 및 exclusive atomic publication 규율로 leaf 입력과 aggregate 출력을 다뤄
  stale success, symlink/path 교체와 기존 output overwrite를 거부한다. evidence 전체 상한은 `release_manifest.max_evidence_bytes`, scalar 상한은
  `release_manifest.max_scalar_string_bytes`를 재사용하고 gate별 배열은 제품 상수에서 유도한 exact bound를 가진다.

  executable filesystem 조립 owner는
  `src/platform/macos/session_host/release_evidence_files.zig` 하나다. caller가 profile과 typed release identity를 선택하면
  이 owner가 A의 `default_false_baseline`·`signed_app_quit_reattach` 또는 B의 `signed_upgrade_one`·
  `signed_upgrade_near_max` leaf를 각각 `readInputAlloc(max_evidence_bytes)`로 완전히 읽고, 열린 fd에서 얻은
  `(device,inode)`가 전부 서로 다른지 확인한다. symlink·special file·oversize·read 중 identity/size/time drift·hardlink alias,
  잘못된 leaf/profile binding 또는 allocation failure에서는 output 경로를 열지 않는다. 모든 leaf가 canonical aggregate bytes로
  조립되고 expected release identity에 다시 bind된 뒤에만 owned `publishSummaryOwnedExclusive`를 exact once 호출한다. 성공은 게시된
  exact inode와 parent capability, size와 digest를 보존한 final-address `PinnedReleaseFile` 하나로만 반환한다. writer가 pathname을
  다시 열어 결과 metadata를 합성하거나 성공 직후 descriptor를 닫아 후속 manifest authoring이 pathname 권위로 되돌아가게 하지 않는다.
  output은 absolute absent leaf여야 하며 기존 파일·symlink를 덮어쓰지 않는다. pre-owned/copied result와 result storage가
  identity·leaf/output pathname storage에 alias되는 입력은 filesystem 접근 전에 거부한다. publication 실패나 parent fsync 실패는
  성공으로 바꾸지 않으며, 기존 file adapter의 temp cleanup/rollback 규율을 그대로 따른다. 이 owner는 환경변수·GitHub API·Apple
  command를 읽지 않고, caller가 준 identity를 provenance로 승격하지도 않는다. trusted context/manifest/attestation과의 결합은 후속
  workflow owner다.

  focused gate `test-session-host-release-evidence`는 A/B canonical round-trip, 모든 scope의
  duplicate/unknown/missing/type/cap, UUID 형식, profile-role/predecessor, leaf 누락·중복·교환, stale run/attempt,
  A/B candidate swap, 1/near-max count·set digest와 leaf/aggregate allocation fail-index를 Debug·ReleaseFast로
  검증한다. 이 component green은 실제 signed app gate 실행, artifact attestation 또는 release workflow 배선을 대신하지 않는다.
  focused gate `test-session-host-release-evidence-files`는 두 profile의 실제 file 조립/publication, leaf inode alias와 symlink,
  malformed·candidate/predecessor mismatch, 기존 output 보존, owned inode revalidation과 owner/input alias, allocation fail-index에서
  publication 0을 Debug·ReleaseFast 및
  macOS actual filesystem으로 검증한다. special/oversize/read-drift는 하위 `test-session-host-release-adapter-files`의 독립
  계약이며 조립 gate가 중복해 완료를 주장하지 않는다. 이 gate도 caller identity의 GitHub provenance나 signed leaf 생산을 증명하지 않는다.

  baseline-A evidence의 trusted workflow 조립 owner는
  `src/platform/macos/session_host/release_adapter_candidate_baseline_evidence.zig`의 단일 진입점이다. 입력은 trusted
  `Context`, final-address `CandidateEvidenceIdentity`와 그 identity가 의존하는 exact `CandidateFiles`·`CandidateProduct`·
  `SourceTreeAuthority`, 동일 candidate pathname, 두 baseline gate leaf pathname과 absent output pathname뿐이다. caller는
  profile, `evidence.Common`, release/source/build/candidate digest, signing requirement 또는 gate 성공 bool을 별도 scalar로
  제출하지 않는다. owner는 첫 revalidation view를 bounded fixed storage에 복사해 aggregate 입력을 봉인하고 그 storage와 모든
  authority/path/result alias를 filesystem 접근 전에 거부한다.

  `release_evidence_files`는 두 leaf를 읽고 canonical aggregate를 다시 bind한 뒤 output parent나 leaf를 열기 직전에 owner의
  publication validator를 exact once 호출한다. validator는 원래 candidate/product/source authority를 다시 revalidate하고 최초
  fixed snapshot과 bytewise exact 일치해야만 no-allocation publication suffix를 연다. 따라서 aggregate encode/parse 중 allocator
  callback이 identity나 backing authority를 바꾸면 output publication은 0이다. 성공은 pathname 재관측이 아니라 held output fd와
  parent capability, size/SHA를 가진 `PublishedEvidence`로 반환한다. focused gate
  `test-session-host-release-adapter-candidate-baseline-evidence`는 exact derivation/publication, caller common/profile 입력 0,
  publication 직전 identity·product·source drift, copied/pre-owned/alias owner, malformed·교환 leaf, 기존 output과 allocation
  fail-index를 Debug·ReleaseFast actual filesystem에서 검증한다. 이 gate는 signed baseline leaf 실행, aggregate artifact
  attestation, manifest authoring·draft attach/publish 또는 frozen U5 제품 E2E를 완료하지 않는다.

  baseline-A signed leaf transaction의 단일 순서 소유자는
  `src/platform/macos/session_host/release_adapter_candidate_baseline_phase.zig`다. trusted candidate identity를 빌린
  final-address 제품 owner가 시작한 하나의 absolute deadline 아래 candidate authority를 먼저 재검증하고 default-false leaf를 실행한 뒤 다시
  candidate authority를
  재검증한 뒤 signed-app-quit leaf를 실행한다. 두 번째 candidate 재검증 뒤에만 기존 baseline evidence owner로 aggregate를
  게시하며, aggregate publication 뒤에도 같은 deadline과 candidate를 마지막으로 검증해야 성공을 반환한다. 각 child는 caller가
  고른 UUID·digest·성공 bool을 받지 않고 같은 candidate identity view에서 입력을 유도해야 한다.

  실패는 attempted child를 역순 정리하고 cleanup failure와 retry owner를 보존한다. focused gate
  `test-session-host-release-adapter-candidate-baseline-phase`는 순서·deadline·fail-index·cleanup을 Debug·ReleaseFast에서 검증한다.

  `release_adapter_candidate_baseline_product.zig`는 execution/경로를, `release_adapter_candidate_baseline_app.zig`는 product의 frozen
  SHA·signer에 보존 app main/CLI의 distinct no-follow inode를 결속한다. drift·alias·digest/signer 불일치는 child 전에 실패한다.
  `release_adapter_candidate_baseline_workspace.zig`는 기존 descriptor-owned workspace SSOT로 caller의 absolute absent root를 0700으로
  만들고 `default-false`·`signed-app-quit` HOME, 두 leaf와 aggregate의 고정 경로를 봉인한다. ambient HOME/config 또는
  `/tmp/maru-<uid>`를 유도하지 않으며 held root identity가 같고 다섯 child가 모두 사라진 뒤에만 empty root를 제거한다. copied owner,
  root 교체·잔여물·sync 실패는 외부 삭제 없이 retry authority를 보존한다.

  baseline 제품 child build entrypoint는 이 owner가 봉인한 두 HOME과 두 leaf absolute pathname을 각각 필수 option으로 받는다.
  `build.zig`가 `zig-out` HOME·leaf 또는 `/tmp/maru-product-test-*` registry를 다시 유도하지 않고, 두 HOME은 absent directory를
  `0700`으로 배타 생성하며 leaf는 시작 시 absent여야 한다. 하위 AppKit 하네스도 caller pathname의 stale file을 unlink하지 않는다.
  따라서 direct 개발 실행도 명시한 격리 workspace 밖을 삭제하지 않으며, production runner는 child 종료 뒤 leaf를 보존하고 HOME의
  config·registry·진단 residue만 자기 child cleanup으로 회수한 다음 workspace owner가 root를 제거한다. 이 entrypoint 경계는
  workspace owner와 child 실행을 연결할 준비일 뿐 candidate revalidation 순서·aggregate publication·전체 production runner를
  완료했다고 주장하지 않는다.

  baseline 제품 leaf process adapter는 `default_false | signed_app_quit` closed kind 하나와 final-address candidate identity,
  보존 app authority, baseline workspace authority를 받아 위 build entrypoint 하나만 실행한다. UUID와 candidate digest는 caller scalar가
  아니라 candidate identity의 첫 revalidation view에서 유도하며, app·DMG·frozen executable·HOME·leaf pathname은 각 authority가
  봉인한 경로만 argv에 들어간다. cwd는 caller가 held directory fd로 보존한 source root이다. Zig executable은 raw pathname이
  아니라 trusted tag workflow가 mise 설치 직후 만든 final-address `ZigToolchainAuthority`에서만 온다. workflow는 canonical absolute
  pathname, regular/executable mode, size, SHA-256과 exact version `0.16.0`을 먼저 고정하고, adapter는 같은 pathname object와 held
  file identity·size·mode·digest를 child 실행 직전과 직후 다시 검증한다. child environment는
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME=/var/empty`,
  `ZIG_GLOBAL_CACHE_DIR=.zig-cache`의 closed 목록이며 cache 상대경로는 held source cwd 안에서만 해석된다. adapter는 하나의 남은
  deadline을 bounded process에 넘기고 실행 전후 candidate·app·
  workspace authority가 최초 snapshot과 일치하는지 확인한다. 시작 전 leaf는 absent여야 하며 exit 0 뒤 exact leaf가 새 regular
  `0600` 파일로 존재할 때만 성공이다. stdout/stderr 내용은 성공 authority가 아니다.

  focused gate `test-session-host-release-adapter-zig-toolchain-authority`는 GitHub-hosted macOS ARM64 tag workflow 결속, canonical
  absolute pathname과 expected size/SHA-256, executable mode, copied/pre-owned owner, pathname·parent·inode·bytes drift를
  Debug·ReleaseFast actual filesystem에서 검증한다. `check-session-host-release-workflow`는 mise 뒤 exact version·path·size·digest
  capture가 baseline 실행보다 먼저 존재하는지 고정한다. focused gate
  `test-session-host-release-adapter-candidate-baseline-child`는 두 kind의 exact argv·closed environment·held cwd·deadline,
  caller UUID/digest/bool 입력 0, 실행 전후 authority drift, foreign capture, 기존·누락·symlink·공개 권한 leaf, timeout·nonzero exit의
  성공 0을 Debug·ReleaseFast에서 검증한다. 이 leaf adapter는 두 child의 순서, aggregate publication, cleanup retry owner 또는 live
  release workflow의 전체 phase 배선을 완료하지 않는다. macOS 공개 API에는 held executable fd와 별도 held cwd를 함께 받는 fd-exec가
  없으므로 그것을 제품 계약으로 두지 않는다. 공식 release의 실행 신뢰 경계는 protected tag·`release` environment의 GitHub-hosted
  격리 runner이며, 같은 UID의 비신뢰 동시 프로세스가 executable pathname을 swap한 뒤 원복하는 공격은 이 경계 밖이다. 로컬 빌드와
  로컬 업그레이드는 이 공식 release evidence 권위를 요구하지 않는다.

  baseline 제품 runner의 production 진입점은
  `src/platform/macos/session_host/release_adapter_candidate_baseline_runner.zig`다. caller가 이미 final-address로 보존한
  candidate identity/files/product/source, candidate app, isolated workspace, official release Zig toolchain과 held source cwd만
  빌리고, caller가 UUID·digest·profile·gate 성공 bool·HOME·leaf/evidence pathname을 별도 제출하지 못하게 한다. runner-owned
  하나의 absolute deadline 아래 기존 product execution owner를 통해 default-false child→candidate 재검증→signed-app-quit
  child→candidate 재검증→baseline aggregate publication→final candidate/deadline 재검증을 실제 adapter로 조립한다.

  성공하면 두 leaf와 held aggregate evidence를 후속 manifest/attestation 단계에 넘길 수 있도록 caller-owned `Execution`에
  보존하며 자동 cleanup하지 않는다. 실패하면 aggregate→signed-app-quit leaf/HOME→default-false leaf/HOME 순으로 exact
  workspace child만 best-effort cleanup하고, cleanup 실패 시 남은 exact retry set과 deadline/evidence owner를 같은 final-address
  `Execution`에 보존한다. copied/pre-owned/authority-storage alias execution, 이미 성공한 execution의 재실행, borrowed authority
  drift와 workspace 밖 삭제는 child 실행 전에 거부한다. focused gate
  `test-session-host-release-adapter-candidate-baseline-runner`는 production-type concrete composition의 순서, 동일 deadline,
  성공 owner 보존, 각 fail-index의 역순 cleanup과 retry를 Debug·ReleaseFast에서 검증한다. 실제 filesystem 권위·publication은 이
  runner가 그대로 호출하는 app/workspace/child/evidence 집중 gate가 각각 검증한다. candidate app의 제품 생성 진입점
  `bindCandidateUntil`은 두 bundle executable을 no-follow held fd로 먼저 고정하고, `/usr/bin/codesign --verify --strict`와
  `/usr/bin/codesign -d --verbose=4`를 closed environment의 bounded process로 각각 실행한다. 각 child 전후에는 상위 release phase의
  같은 final-address `Deadline`에서 fresh remaining을 얻고 candidate product와 두 held inode를 다시 검증한다. main과 CLI의
  `TeamIdentifier`는 각각 정확히 하나인 유효한 10자리 값이어야 하며 `CandidateProduct`의 Apple observation에서 유도한 exact
  Team ID와 같을 때만 `CandidateApp`을 게시한다. 내부 실행파일의 identifier가 서로 다르므로 각 designated requirement digest를
  앱 번들 digest와 같다고 요구하지 않는다. caller는 signer 값이나 성공 bool, command path·argv·timeout을
  제출하지 않는다. copied/pre-owned result, result/path/deadline alias, symlink·hardlink, executable 또는 candidate drift,
  timeout·output cap·strict signature/team identity failure는 app authority publication 0이고 열린 fd를 모두 닫는다. focused gate
  `test-session-host-release-adapter-candidate-baseline-app`은 실제 executable filesystem과 injected signer observer 및 제품이 직접
  소비하는 command plan으로 exact command/environment/order/deadline, 각 drift와 fail-index를 Debug·ReleaseFast에서 검증한다. workspace와 app을 만들고
  runner까지 하나의 owner로 묶는 transaction, artifact attestation, manifest/draft publication과 live release workflow 호출은
  후속 wiring이다.

  baseline 준비 transaction의 단일 순서 소유자는
  `src/platform/macos/session_host/release_adapter_candidate_baseline_preparation.zig`다. caller가 선택한 positive budget으로
  final-address absolute deadline을 exact once 시작한 뒤, absent baseline root에 workspace를 준비하고 같은 deadline 아래 candidate
  app을 결속한 다음 기존 baseline runner를 **새 deadline을 시작하지 않는 borrowed-deadline 진입점**으로 exact once 실행한다.
  workspace·app·runner는 각각 기존 production adapter가 의미와 filesystem 권위를 계속 소유하며, transaction은 caller가 이 셋의
  순서나 deadline identity를 바꾸거나 일부 성공만 꺼내 갈 수 없게 하는 orchestration owner다. runner 성공 뒤 candidate와 deadline을
  마지막으로 재검증하고 deadline을 정리한 경우에만 workspace·app·두 leaf·aggregate evidence를 하나의 성공 owner로 게시한다.

  deadline 시작 실패는 side effect 0인 failure-pristine leaf다. 그 뒤 실패는 attempted runner→app→workspace 순서로 best-effort
  cleanup하고 마지막에 deadline을 정리한다. cleanup이 모두 성공하면 transaction은 empty로 돌아가 원래 오류를 보존한다. 어느
  cleanup이든 실패하면 원래 오류보다 `CleanupFailed`가 우선하며, 아직 정리되지 않은 exact owner만 같은 final-address transaction에
  남겨 `retryCleanup`으로 다시 회수한다. 성공 owner의 cleanup도 같은 역순이며 일부 cleanup 성공 뒤 뒤 단계가 실패하면 성공한 owner를
  다시 만들지 않고 남은 retry set만 보존한다. transaction은 no-side-effect preflight를 deadline 시작보다 먼저 호출해야 하며,
  copied/pre-owned transaction과 concrete transaction/deadline/workspace/app/runner 또는 root/path storage alias는 이 preflight에서
  filesystem·child 전에 fail-close해야 한다. workspace·candidate app authority drift도 runner 실행 전에 닫는다. focused gate
  `test-session-host-release-adapter-candidate-baseline-preparation`은 preflight 선행, exact order와 shared deadline identity, 각
  fail-index의 attempted reverse cleanup, deadline-start pristine failure, 성공 owner 보존, partial cleanup retry와 terminal empty state를
  Debug·ReleaseFast로 검증한다. concrete storage alias 행렬과 실제 authority drift는 후속 production wiring gate가 소유한다. 이 gate는
  leaf 의미를 복제하거나 artifact attestation, manifest/draft publication, live release workflow 호출 또는 frozen U5 제품 E2E를
  완료했다고 주장하지 않는다.

  baseline 준비 transaction의 production owner는
  `src/platform/macos/session_host/release_adapter_candidate_baseline_preparation_product.zig`의 caller-owned final-address
  `Execution`이다. trusted context와 candidate identity/files/product/source, product·app 경로, official release Zig toolchain과 held
  source cwd, caller가 지정한 absent workspace root, positive budget만 입력으로 받는다. caller는 workspace/app/runner owner, deadline,
  leaf·evidence pathname, UUID·digest·signer 또는 gate 성공 bool을 제출하지 않는다. production preflight는 `Execution`과 그 내부
  transaction/deadline/workspace/app/runner storage, 모든 borrowed authority, path storage가 겹치지 않고 source fd가 유효한지 deadline
  시작과 filesystem 접근 전에 검사한다.

  concrete steps는 같은 `Execution` 안에서 deadline을 시작하고 workspace를 준비한 뒤, `bindCandidateUntil`로 app main/CLI를 같은
  deadline에 결속한다. 이어 기존 baseline runner의 `runBorrowingDeadline`을 호출한다. 이 진입점은 새 deadline을 만들지 않으며,
  caller deadline의 final-address identity를 실행 내내 보존하고 기존 child 순서·evidence publication·cleanup 계약을 그대로 사용한다.
  runner 성공 뒤 candidate identity/files/product/source, app, workspace, toolchain과 deadline을 다시 검증하고 deadline을 닫은 다음에만
  complete owner를 게시한다. 성공 owner의 cleanup과 실패 retry는 generic transaction이 정한 runner→app→workspace→deadline 순서를
  production owner에 직접 적용하며, 정리된 owner를 재생성하거나 workspace 밖 pathname을 삭제하지 않는다. 실패 즉시 borrowed input을
  지우고 cleanup failure 때만 아직 live인 exact nested owner와 cleanup에 필요한 io/allocator를 보존한다. runner cleanup이 실패하면
  그 retry가 workspace capability를 계속 사용하므로 workspace cleanup도 dependency-live로 실패시켜 둘을 함께 보존하고, runner가 먼저
  정리된 재시도에서만 workspace를 제거한다. owner가 null이어도 nested fd·deadline timestamp·attempt state가 남은 dirty execution은
  pristine으로 승격하지 않는다.

  focused gate `test-session-host-release-adapter-candidate-baseline-preparation-product`는 invalid/copied/pre-owned execution과 concrete
  object/path alias의 side effect 0, exact production type wiring, runner의 borrowed-deadline identity와 own-deadline 생성 0, authority
  drift, 성공 owner 및 cleanup, 각 production step failure의 reverse cleanup, cleanup-failure retry state와 sensitive borrow scrubbing을
  Debug·ReleaseFast로 검증한다. 실제 codesign/filesystem child 성공은 이 owner가 직접 호출하는 app/workspace/runner 집중 gate가 각각
  검증한다. artifact attestation, manifest authoring·draft attach/publish, live release workflow 호출과 frozen U5 제품 E2E는 아직 후속
  wiring이다.

  upgrade-B evidence의 trusted workflow 조립 owner는
  `src/platform/macos/session_host/release_adapter_candidate_upgrade_evidence.zig`의 단일 진입점이다. 입력은 baseline과 동일한
  final-address `CandidateEvidenceIdentity` 및 backing candidate/product/source authority, final-address
  `PredecessorEvidenceIdentity` 및 backing authenticated manifest/held manifest file/downloaded asset authority, 두 upgrade leaf
  pathname과 absent output pathname뿐이다. caller는 `evidence.Common`, `evidence.Predecessor`, designated-requirement digest,
  profile 또는 gate 성공 bool을 별도 scalar로 제출하지 않는다.

  owner는 candidate와 predecessor의 첫 revalidation view를 한 fixed snapshot으로 복사하고, 두 signed leaf를 canonical
  upgrade aggregate로 조립·bind한 뒤 output open 직전에 양쪽 authority graph를 모두 다시 revalidate한다. 최초 snapshot과
  release/source/build/candidate/predecessor/signing requirement가 bytewise exact 일치해야만 allocation 없는 exclusive publication
  suffix를 연다. result와 authority/path storage alias, copied/pre-owned owner, allocator callback 중 candidate·predecessor·held inode
  drift, leaf 교환·malformed·기존 output에서는 publication 0이다. 성공은 held output inode authority 하나로 반환한다. focused gate
  `test-session-host-release-adapter-candidate-upgrade-evidence`는 이 계약을 Debug·ReleaseFast actual filesystem에서 검증한다. 이
  gate는 signed upgrade leaf 자체 실행, aggregate attestation, manifest/draft attach/publish 또는 frozen U5 제품 E2E를 완료하지 않는다.

  manifest 자체나 evidence를 build 뒤 사람이 고쳐 넣을 수 없도록 같은 trusted release run이 aggregate를 생성하고 artifact
  attestation을 발급한다. attestation 검증은 repository·workflow·source commit·run identity와 subject digest를 모두 policy
  input으로 사용하며 단순히 cryptographic valid만으로 통과시키지 않는다.

  publish 순서는 닫혀 있다. trusted tag workflow가 후보 bytes에 artifact attestation을 발급하고 draft release ID를 얻은 뒤,
  그 후보로 제품 gate를 실행해 evidence를 만든다. 그 다음에야 release ID와 evidence digest를 담은 manifest를 생성·attest하고
  manifest와 그 manifest가 열거한 모든 asset을 draft에 attach한다. draft를 다시 내려받아 pre-publish validator가 검사한 뒤에만 publish한다. immutable release
  attestation은 publish 뒤에만 생기므로 자기 publish의 선행조건으로 순환 참조하지 않는다. 대신 후보/manifest artifact
  attestation과 manifest digest가 pre-publish trust를 맡고, publish 직후
  `gh release verify`/`verify-asset`에 해당하는 검증이 tag·commit·asset 결속을 확인해 release audit artifact를 남긴다.
  B가 A를 소비할 때는 이 post-publish release attestation까지 필수다. 공개 뒤 검증 실패는 asset 교체나 `--clobber`로
  복구하지 않고 그 release를 실패 기록으로 보존한 채 새 version으로 다시 출하한다.

  draft release ID의 최초 권위는 shell의 `gh release create` stdout이나 caller scalar가 아니다.
  `release_adapter_github_draft_creation.zig`의 final-address move-only `DraftAuthority`가 단일 소유자다. trusted context와 checkout 전
  pin한 CLI, validated token, 같은 release phase `Deadline`만 받아 exact repository endpoint에 mutable draft를 한 번 생성한다.
  closed request는 exact tag, source commit, title, `draft=true`, `prerelease=false`, release-note generation만 전달하며 caller가 endpoint,
  method, field name 또는 기존 release ID를 고르지 못한다. CLI authority와 deadline은 child 전후에 재검증하고 bounded response는
  strict JSON으로 parse해 nonzero ID, exact tag/source/title, draft/prerelease/immutable state를 current context와 결속한다. 이미 존재하는
  release, duplicate/missing/wrong-type field, foreign target, child failure, timeout, copied/pre-owned result는 authority publication 0이다.
  child가 성공을 반환한 뒤 로컬 parsing·publication이 실패하면 remote draft가 남을 수 있으므로 자동 재생성·기존 release 재사용·삭제로
  성공을 합성하지 않는다. strict response에서 ID까지 결속한 뒤의 로컬 publication 실패는 exact created ID를 보존한
  terminal cleanup-required 상태로, 응답이 malformed이거나 ID 결속 전에 allocation이 실패한 경우는 ID를 추측하지 않는
  terminal remote-state-unknown 상태로 workflow를 멈추고 사람이 감사한 뒤 처리한다.
  focused gate `test-session-host-release-adapter-github-draft-creation`은 exact mutation argv, clean environment, response binding,
  shared deadline, CLI drift, remote-created 뒤 local failure의 비재시도 상태와 allocation fail-index를 Debug·ReleaseFast에서 검증한다.
  이 owner가 생기기 전에는 evidence/manifest authoring이나 validator workflow 배선을 완료했다고 주장하지 않는다.

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
  같은 runtime에서 출력돼야 한다. 마지막에는 exit 23을 수행하는 명령으로 shell을 끝내고 host가 child를 reap해 runtime
  inventory에서 정확히 한 번 제거한 뒤에만 client/oneshot daemon을 종료한다. 단순 codec round-trip, parent가 test
  runner인 inherited PTY, 화면 marker만 보이는 fixture는 이 gate의 증거가 아니다.
  이 test-only 수명 제어와 marker 환경은 launcher가
  일반 detached product launch 전에 지우는 목록에 계속 포함하고, fixture가 직접 fork/exec한 owner-only 임시
  session/socket root에서만 허용한다. 따라서 ambient environment만으로 실제 사용자 daemon을 oneshot으로 만들거나
  성공 marker를 위조할 수 없어야 한다. zero-runtime gate는 `test-session-host-upgrade-product-rollback`에서
  canonical product rollback exec 뒤 동일 peer PID의 실제 client handshake, old build/epoch, `rolled_back/restore_failed`,
  upgrade capability와 exact empty inventory를 자동 검증한다. 따라서 zero-runtime의 실제 제품 rollback activation과
  listener 재접속은 구현·실행됐다. `test-session-host-upgrade-nonempty-rollback`은 supervised source-host가
  production `RuntimeManager`로 만든 실제 PTY를 quiesce/capture한 뒤 corrupt primary→canonical product rollback을
  같은 PID에서 실행한다. wire 검증은 exact runtime ID, direct-child PID, rollback 전 snapshot marker, rollback 뒤
  input marker, exit-23 명령 뒤 host-owned child reap/runtime 제거를 함께 단언한다. exit status 숫자 자체는 현재 wire로
  노출하지 않으므로 이 gate의 관측 증거라고 주장하지 않는다. 따라서 non-empty PTY rollback 종료 gate도
  구현·실행됐다.
- **아직 미구현 또는 미실행인 제품 종료 gate:** release manifest로 provenance가 고정된 signed frozen
  N-1/current artifact를 사용한 위 성공 gate의 실제 통과, 1개·최대치 근처
  multi-runtime의 제품 daemon→product restore→GUI exact reattach, manifest/reader/socket/FD/promotion 전 구간
  failure injection, 실제 앱 재실행 notice와 장시간 soak가 남아 있다(typed 업그레이드 결과는 GUI의
  connect 경로와 one-shot notice에 연결됐지만 실제 두 앱 이미지 재실행 화면 증거는 별도다). macOS 공개 API에는 fd-based
  exec가 없으므로 kernel-loaded-image pin은 목표에서 제거하고, 마지막
  pathname object identity 재검증+same-designated-requirement signer+same-UID owner boundary를 제품 계약으로 쓴다.
  이 종료 gate가 닫히기 전에는 U5 완료를 주장하지 않는다.

- **failure matrix의 첫 named gate:** `test-session-host-upgrade-failure-matrix`는 이미 독립적으로 존재하던
  U3 same-PID process failure 14개와 U5 zero/non-empty 제품 rollback activation을 한 진입점에서 실행한다.
  이 gate는 corrupt primary·corrupt/divergent backup, incompatible/hung target preflight, old/second exec 반환,
  target adoption 실패, target pathname identity 교체, 연속 upgrade rollback, promotion 실패와 실제 제품
  rollback listener/runtime 수명을 고정한다. 목록은 boundary inventory가 exact test 이름과 build dependency를
  검사하므로 테스트가 조용히 빠진 green을 허용하지 않는다. 다만 같은 source에서 빌드한 U3 fixture와 current
  제품 rollback 증거의 집합이므로 signed frozen release provenance나 아직 목록에 없는 manifest/socket/FD 전 구간
  failure를 대신하지 않으며, 이 첫 matrix만으로 U5 failure injection 완료를 주장하지 않는다.
- **failure matrix의 두 번째 component gate:** `test-session-host-upgrade-component-failure-matrix`는
  `handoff_store.zig` 9개, `exec_fd_set.zig` 6개, `host_authority.zig` 3개,
  `upgrade_target.zig` 5개의 exact module inventory를 한 진입점에서 실행한다. 이 23개는 primary/backup
  commit·reservation·residue cleanup, reserved slot/CLOEXEC rollback, discovery manifest CAS,
  target staging·pin·replacement cleanup의 현재 component seam을 고정한다. boundary inventory는 네 source의
  exact test title·개수와 named step의 네 dependency를 함께 검사한다. 이 gate는 existing component 증거가
  release 검증에서 빠지는 것을 막지만, socket owner와 제품 coordinator를 통과하는 end-to-end failure
  injection을 새로 증명하지 않는다. 따라서 이 두 번째 matrix만으로도
  위의 manifest/reader/socket/FD/promotion 전 구간 종료 gate를 닫았다고 주장하지 않는다.
  추가된 `test-session-host-upgrade-reserved-handoff-failures` 집중 gate는 제품이 쓰는 pre-quiesce
  `Reservation`→`commitReserved` 경로에서 primary/backup file sync, attempt directory pre/post-readback sync,
  primary/backup unlink, attempt directory removal, owner directory sync 실패를 각 syscall 직전의 test-only
  one-shot seam으로 주입한다. 모든 행은 `Pair`를 publish하지 않고 caller의 `Reservation.cancel`이 열린 fd와
  owner-pinned attempt residue를 exact cleanup하는지 검증한다. 이는 syscall 경계 오류 처리 증거이지 실제 disk
  fault를 일으킨 kernel integration test가 아니다.
  `test-session-host-upgrade-reservation-cleanup-failure` 집중 gate는 reserved primary pathname이 다른 inode로
  교체된 뒤 `Reservation.cancel`을 실행한다. cleanup은 교체 inode를 삭제하지 않고 `CleanupFailed`를 반환하며,
  original primary/backup, attempt/owner와 내부 readback fd를 모두 닫고 reservation을 terminal inactive로 만든다.
  제품 coordinator가 이 오류를 `invariant_violation` 외의 retryable terminal로 축소하지 않는 source boundary도 같은
  inventory가 고정한다. 이는 실제 pathname identity 충돌의 component 증거와 제품 mapping 경계이며, 제품 process가
  outer loop에서 실제 fail-stop하는 E2E나 두 개 이상의 실제 kernel cleanup syscall fault 주입을 대신하지 않는다.
  `test-session-host-upgrade-coordinator-cleanup-fail-stop` 집중 gate는 공개 `Context`를 넓히지 않는 coordinator-private
  test hook으로 budget reservation 직후 같은 primary identity 충돌을 만든다. 실제 `processArmed` 흐름은 reserved commit
  실패 뒤 old graph를 재개하고 terminal report를 만든 다음 reservation cleanup도 실패하므로 최종 결과를
  `invariant_violation`으로 덮어써야 한다. 같은 named gate는 `upgrade_loop`의 exact test도 함께 실행해
  `invariant_violation`이 retryable terminal이 아니라 `fail_stop`으로만 분류되는지 고정한다. 이는 실제 coordinator와
  outer-loop 분류의 실행 증거지만 daemon process가 socket을 닫고 nonzero로 종료하는 process E2E는 별도다.
  `test-session-host-upgrade-daemon-cleanup-fail-stop` 집중 gate는 그 별도 process E2E를 소유한다. 부모 test는 실제
  fork child에서 exact-identity daemon과 제품 `SocketServer`/poll owner/coordinator를 띄우고, GUI profile client가
  제품 `host.upgrade.prepare` wire 요청을 보낸다. child에 명시적으로 전달한 test-only fault는 budget reservation 직후
  primary pathname을 다른 inode로 교체한다. 따라서 실제 coordinator가 old graph를 재개한 뒤 cleanup identity 실패를
  `invariant_violation`으로 만들고, 공유 outer loop가 이를 `fail_stop`으로 분류해 daemon을 `ManifestFailed`로 반환해야 한다.
  child wrapper는 이 exact error만 전용 nonzero exit code로 바꾸며 다른 error와 정상 반환을 별도 code로 구분한다.
  부모는 deadline 안의 그 exact exit, 기존 sibling 연결의 typed 폐쇄 실패, listener 재접속 거부, socket pathname 부재,
  owner lease pathname 부재를 모두 관측해야 성공한다. fault는 ambient environment나 MRSH test command가 아니라
  `builtin.is_test`로 닫힌 fixture entrypoint의
  typed 값으로만 전달하고, 제품 entrypoint와 공개 coordinator `Context`에는 주입 필드를 추가하지 않는다. 이 gate는
  실제 kernel pathname 교체 한 종류와 daemon unwind를 증명하지만 disk-full, fsync, 다중 cleanup syscall fault나 실제 서명
  release artifact를 대신하지 않는다.
  `test-session-host-upgrade-kernel-cleanup-faults` 집중 gate는 synthetic pre-syscall failpoint 대신 실제 macOS filesystem
  조건을 만든다. component 행은 reservation의 열린 attempt directory를 읽기 전용으로 바꾼 뒤 제품
  `Reservation.cancel`을 호출한다. pinned primary/backup 제거는 실제 kernel에서 `EACCES`, 파일이 남은 attempt directory
  제거는 `ENOTEMPTY`여야 하며, cleanup은 두 번째 실패 뒤에도 owner sync/close까지 진행해 aggregate `CleanupFailed`, terminal
  inactive와 reservation fd 전량 폐쇄로 수렴해야 한다. test-only observation은 syscall 직후 errno만 기록하며 syscall 결과를
  대신 만들거나 제품 error mapping을 바꾸지 않는다. 같은 named gate의 process 행은 budget reservation 직후 동일 권한 조건을
  만드는 typed fixture를 실제 fork daemon의 제품 `Client.prepareUpgrade` 경로에 연결한다. daemon 행은 각 errno를 직접
  노출한다고 주장하지 않고 coordinator `invariant_violation`→outer-loop `fail_stop`→`ManifestFailed` exact nonzero exit와 기존
  sibling, 새 연결, socket pathname, owner lease pathname의 폐쇄를 증명한다. fixture는 `builtin.is_test`로 닫히고 ambient
  environment, MRSH command, 공개 coordinator `Context`를 넓히지 않는다. 이 component+process 결합으로 두 개 이상의 실제
  kernel cleanup syscall fault와 daemon fail-stop은 닫지만 disk-full, fsync fault와 실제 서명 release artifact는 여전히 별도다.

  `test-session-host-upgrade-disk-full-admission` 집중 gate는 user-owned HFS+ disk image에 실제 fork daemon의 owner
  directory를 만들고 제품 target staging이 끝난 뒤에만 coordinator-private typed fixture로 같은 volume의 bounded
  incompressible filler를 실제 kernel `ENOSPC`까지 쓴다. 그 다음 호출은 synthetic error가 아니라 제품
  `budget_admission.prepare`여야 하며, two-copy `F_PREALLOCATE` 또는 durable probe write가 실패해 reader pause 전에
  `resumed/state_too_large`로 끝나야 한다. 부모는 accepted reply 뒤 새 제품 connection에서 terminal attempt status를
  읽고, accepted drain의 기존 sibling은 typed 폐쇄되지만 새 연결의 daemon PID·listener·`host.info`·exact runtime
  inventory가 유지되며 attempt reservation residue가 없음을 검증한다. disk image detach와 filler 정리는 harness owner가
  exact path로 수행한다. fixture는 `builtin.is_test`로 닫고
  ambient environment, MRSH command, 공개 coordinator `Context`와 제품 error mapping을 넓히지 않는다. 이 gate는 실제
  write-side disk-full admission과 pre-quiesce 생존만 닫는다. ENOSPC 뒤 성공하는 fsync를 fsync fault로 세지 않으며 delayed
  fsync fault와 실제 서명 release artifact는 여전히 별도다.

signed non-empty 성공 gate는 복원 뒤 화면 marker만 확인하고 `runtime.terminate`로 정리해서는 닫히지 않는다.
복원된 PTY가 읽는 명시적 종료 marker를 입력하고, 그 child가 종료된 뒤 host가 직접 reap하여 `runtime.list`에서
exact runtime ID를 제거해야 한다. 검증자는 같은 연결에서 inventory 부재를 두 번 관측하고 direct-child 부재도
확인해 stale 한 번이나 client-side 숨김을 성공으로 세지 않는다. 현재 wire는 exit status를 노출하지 않으므로
shell의 `exit 23` 숫자 자체를 관측했다고 주장하지 않고, 명령 전달·child 종료·host-owned reap·inventory exact-once
제거를 증거로 삼는다.

1-runtime 제품 성공 gate의 복원 후 소비자는 raw `runtime.attach` 시험 클라이언트가 아니라 GUI가 실제로 쓰는
`RemoteRuntime.attachExisting`이어야 한다. 저장된 exact `runtime_id`로 새 GUI-side runtime을 만들고, 최초 full-state에
업그레이드 전 marker가 있으며 그 객체의 `sendInput`/`pumpDelta`로 업그레이드 후 marker가 보이는지 확인한다. raw client로
inventory와 stream만 읽는 것은 host restore 증거일 뿐 GUI exact reattach 증거로 세지 않는다. 이 하네스가 구현돼도 실제
signed frozen release artifact 실행 전에는 1-runtime 제품 gate를 통과했다고 주장하지 않는다.

near-max 제품 성공 gate는 `max_runtime_count - 1`인 255개의 **실제 PTY child**를 한 제품 daemon에 만들고 같은
attempt로 전량 restore한다. 각 runtime은 index가 들어간 서로 다른 pre/post marker를 가져야 하며, restore 뒤 typed
inventory는 저장한 255개 exact ID와 중복·누락 없이 같아야 한다. 검증자는 각 ID를 차례로
`RemoteRuntime.attachExisting`해 자기 pre marker만 가진 최초 full-state와 자기 post input/delta를 확인한다. 한 runtime의
화면이나 ID를 255번 재사용하거나 codec DTO 255개만 round-trip하는 것은 이 gate의 증거가 아니다. 종료도 모든 child에
각자의 exit marker를 보내고 inventory와 direct-child set이 모두 비어야 끝난다. 이 부하 gate는 1-runtime gate와 별도
named release step/artifact로 실행하며, 실제 frozen signed artifact가 없으면 skip이나 fixture 성공으로 대체하지 않는다.

U5 제품 종료 gate가 닫히기 전에는 “구 host session migration 완료”를 제품/PR에 쓰지 않는다. 자동 시도가 기본
경로에 연결된 것과 “migration이 검증됐다”는 것은 다르다 — 전자는 연결됐고, 후자는 위 gate가 닫혀야 성립한다.
U1~U4와 현재 U5 component seam은 제품 완료가 아니라 기반 증거다.

### 11.29 evidence summary의 게시 inode 권위

manifest authoring이 evidence summary의 size와 SHA-256을 권위 있게 기록하려면 게시 뒤 pathname을 다시 열어
관측해서는 안 된다. 그 사이는 다른 inode로 교체될 수 있으므로 publication과 manifest observation 사이에
TOCTOU가 생긴다. `release_adapter_files.publishSummaryOwnedExclusive`는 caller가 제공한 final-address 빈 owner와
absolute absent pathname, canonical bytes만 받고 다음 순서를 한 번에 소유한다.

1. no-follow로 연 parent directory 아래 0600 임시 regular file을 `O_RDWR|O_EXCL`로 만든다.
2. complete write와 file sync 뒤 같은 열린 fd에서 regular/type, link-count 1, size와 SHA-256을 계산한다.
3. `RENAME_EXCL`로 absent final leaf에 게시하고 parent directory를 sync한다.
4. final pathname을 no-follow로 다시 열어 held fd와 같은 inode인지 확인한 뒤, held fd와 parent fd를 move-only
   owner에 넘긴다. caller는 이 owner의 value만 manifest observation으로 쓰며 후속 경계마다 pathname을
   revalidate한다.

성공한 owner는 게시된 파일을 삭제할 권한을 뜻하지 않는다. `deinit`은 fd만 닫고 durable output은 남긴다.
rename 또는 parent sync 뒤 실패한 publication은 held fd와 leaf의 device/inode가 여전히 같을 때만 best-effort
unlink와 parent sync를 수행하며 owner를 비워 둔다. pathname이 교체됐으면 foreign leaf를 지우지 않고 residue를 남긴다.
기존 `publishSummaryExclusive`는 이 owned publication을 호출한 뒤 owner를 닫는 호환 wrapper로 유지한다.
이 component는 evidence/manifest 조립, GitHub 업로드, workflow 배선이나 U5 제품 성공을 증명하지 않는다.

manifest authoring이 aggregate evidence의 profile과 identity를 다시 bind할 때도 pathname을 새 입력 권위로 열지 않는다.
`PinnedReleaseFile.readHeldAlloc`은 final pathname이 여전히 held inode를 가리키는지 전후로 revalidate하되, 실제 bytes는 기존 held
fd에서 exact size만 `pread`한다. read 전후 file/parent fingerprint, EOF, SHA-256과 최초 publication observation이 모두 같아야
`Input`을 반환한다. cap 초과, copied owner, pathname 교체, short/extra read, inode·metadata·digest drift와 allocation failure에서는
bytes publication 0이며 foreign replacement를 삭제하거나 수정하지 않는다. focused `test-session-host-release-adapter-files`의 held
evidence 행은 actual filesystem에서 exact bytes/identity와 pathname replacement·allocation failure를 검증한다. manifest semantic
authoring과 GitHub upload는 후속 gate다.

### 11.30 candidate release manifest authoring 권위

candidate release manifest는 workflow shell이 repository/release/source/build, compatibility, signing, asset metadata 또는
evidence 결과를 scalar로 조립하지 않는다. `release_adapter_candidate_manifest.zig`의 단일 owner가 trusted `Context`,
final-address `CandidateEvidenceIdentity`, `CandidateFiles`, `CandidateProduct`, `SourceTreeAuthority`,
`CandidateCompatibility`, 게시된 `PublishedEvidence`와 그 final pathname을 함께 소비한다. role B만 final-address
`PredecessorEvidenceIdentity`와 그 backing authenticated manifest/file/assets authority를 추가로 요구한다. role/profile은
held evidence bytes의 canonical parser 결과에서만 정하고 caller가 별도로 고르지 않는다.

owner는 evidence를 `PinnedReleaseFile.readHeldAlloc(max_evidence_bytes)`로 읽어 canonical parse한 뒤 candidate identity와
role A common 또는 role B common+predecessor+designated requirement를 exact bind한다. manifest repository/release/source/build,
candidate DMG·frozen executable SHA, Apple signing과 compatibility는 각 typed authority에서만 유도한다. 세 asset의 name은
각 held pathname의 basename, size/SHA는 held file observation에서 유도하고 evidence의 `test_uuid`, exact `passed`,
summary name/SHA도 parsed evidence와 held observation에 함께 결속한다. manifest filename은 exact
`Maru-<version>-session-host-release.json`이며 absolute absent pathname만 허용한다.

최초 authority graph를 fixed snapshot으로 봉인하고 canonical manifest encode와 self-parse 뒤 output open 직전에 candidate,
product, source, compatibility, evidence held inode와 role B predecessor graph를 모두 다시 검증한다. 최초 snapshot과 하나라도
다르면 publication 0이다. result/authority/path alias, copied·pre-owned result, malformed·교환 evidence, role/predecessor 불일치,
기존 output과 allocation failure도 publication 0이며 성공은 held manifest inode authority 하나만 반환한다. 이 gate는 aggregate
artifact attestation, draft asset attach, pre-publish validation/publish 또는 frozen signed U5 제품 E2E를 완료하지 않는다.
manifest가 evidence와 같은 parent에 게시되어도 exact evidence leaf의 held/reopened inode·mode·size·digest 결속은 계속 유효해야 한다.
일반 release-file revalidation은 held parent의 directory identity와 mode를 검증하되 sibling 생성에 따라 변하는 mtime/ctime을 input
무효화 권위로 쓰지 않는다. executable 실행 직전의 별도 `PathMutationSeal`만 directory mutation을 봉인한다.

### 11.31 authored evidence와 manifest artifact attestation 권위

같은 trusted release run이 생성한 aggregate evidence와 candidate manifest도 pathname이나 caller가 제출한 SHA를 곧바로
artifact-attestation subject로 승격하지 않는다. `release_adapter_candidate_authored_attestation.zig`의 단일 composition이
final-address `PublishedEvidence`와 held candidate manifest, manifest authoring에 사용한 typed authority graph, checkout 전에 고정한
GitHub CLI, validated token과 같은 release phase `Deadline`을 함께 소비한다. role B predecessor graph의 유무는 caller가 고르는
flag가 아니라 held evidence의 canonical profile과 manifest role에서만 결정한다.

composition은 두 held fd에서 bytes를 읽고 `release_evidence.parseCanonical`과 `release_manifest.parseCanonical`로 다시 해석한다.
manifest author의 공용 revalidation entrypoint가 candidate identity/files/product/source/compatibility, evidence와 role B predecessor를
다시 결속하며, manifest의 evidence name/SHA와 asset row가 exact held evidence observation을 지목하는지 확인한다. 이 entrypoint가
manifest authoring 의미를 단일 소스로 소유하며 attestation composition은 repository/release/source/build/signing/asset 비교를
복제하지 않는다. canonical bytes, typed graph 또는 held file identity가 맞지 않으면 child를 실행하지 않는다.

artifact attestation은 aggregate evidence 다음 manifest 순서로만 실행한다. 각 child 직전에 같은 deadline의 fresh remaining을 얻고,
pinned CLI와 두 held file, typed graph를 다시 검증한다. subject는 각 held pathname의 exact basename과 held fd에서 계산된 SHA-256이며
기존 `release_adapter_github_attestation.verifyWith`가 exact repository, workflow, source commit, run ID/attempt와 subject를 판정한다.
각 child 뒤에도 두 file과 CLI를 재검증하고, 두 receipt가 모두 verified이며 기대 run/subject와 일치한 뒤 마지막 allocation 없는
revalidation과 deadline 확인을 통과해야 final-address move-only `AuthoredAttestation`을 게시한다.

copied/pre-owned result, result/output buffer/authority/path alias, evidence-manifest inode alias, pathname 교체, canonical 또는 cross-binding
불일치, role/predecessor 교환, CLI drift, timeout, 첫째 또는 둘째 child 실패와 allocation failure에서는 receipt publication 0이다.
첫 attestation이 원격에 존재해도 둘째 실패를 성공으로 합성하거나 기존 receipt를 재사용하지 않는다. 이 gate는 attestation 발급
workflow 명령, draft asset attach, pre-publish redownload/validator, publish 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.32 단일 subject artifact attestation 발급 action

release workflow는 여러 artifact를 한 `actions/attest` 호출에 넘기지 않는다. 공식 action의 multi-subject 모드는 한 statement에
여러 subject를 넣지만 Maru verifier는 statement 하나당 subject 정확히 하나를 요구한다. 따라서 candidate DMG, frozen executable,
aggregate evidence와 manifest는 `.github/actions/session-host-release-attest/action.yml`을 각각 한 번씩 호출한다. local composite action은
`actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6`을 immutable SHA로 고정하며 caller가 action ref, predicate 또는 subject digest를
선택하게 하지 않는다. workflow job의 `id-token: write`, `attestations: write`, `artifact-metadata: write` 권한과 protected tag/release
environment 제한은 최종 live wiring gate가 함께 검증한다.

입력 subject는 glob이나 목록이 아닌 canonical absolute regular-file pathname 하나와 exact basename 하나다. action은 checkout 이후
PATH 도구 대신 runner platform의 절대경로 시스템 도구를 쓰고 Darwin/BSD와 Linux/GNU의 stat·SHA-256 형식을 명시적으로 분기한다. 양쪽은
symlink·hardlink·glob/CSV/control character·basename 불일치를 거부하고, action 호출 전에
device/inode/link-count/size와 SHA-256을 step output으로 봉인한다. 공식 action에는 caller pathname을 다시 열게 하지 않고 내부에서
봉인한 `sha256:<digest>`와 exact subject name 하나만 provenance 기본 모드로 넘긴다. 호출 뒤 같은 pathname의
device/inode/link-count/size/SHA가 모두 같아야 composite output을 게시한다.
pre/post mismatch, child failure 또는 빈/control-character output에서는 성공 output을 만들지 않는다.
발급 output 자체는 release 권위가 아니며 candidate 또는 authored attestation typed verifier가 exact workflow/run/source/subject를
다시 확인해야 다음 단계로 갈 수 있다. 이 component만으로 live release workflow 순서, draft attach·redownload·publish 또는 U5 E2E가
완료됐다고 주장하지 않는다.

### 11.33 exact draft asset attachment 권위

draft에는 caller가 고른 glob이나 tag 기반 convenience upload가 아니라, 앞서 생성한 exact `DraftAuthority.id`에 candidate DMG,
frozen executable, aggregate evidence와 candidate manifest 네 asset을 정확히 한 번씩 attach한다.
`release_adapter_github_draft_asset_attachment.zig`의 final-address move-only `DraftAssets`가 trusted `Context`, `DraftAuthority`,
`CandidateAttestation`, `AuthoredAttestation`, 네 held file owner와 canonical held manifest, checkout 전에 고정한 GitHub CLI,
validated token 및 같은 release phase `Deadline`을 함께 소비한다. caller는 release ID, asset name/size/SHA, endpoint, upload 순서,
`--clobber` 또는 성공 bool을 별도 scalar로 제출하지 않는다.

composition은 held manifest를 canonical parse하고 그 manifest 자체를 제외한 세 asset row가 exact role 순서로 DMG, frozen executable,
evidence를 지목하는지 확인한다. 네 pathname의 basename, held inode의 size/SHA와 candidate/authored attestation receipt가 모두 같은
repository/tag/source/workflow run 및 draft ID에 결속돼야 한다. 네 inode는 서로 달라야 하며 pathname은 upload 전후에 각 held owner로
재검증한다. held input fd의 regular-file 판정은 target별 libc syscall을 직접 부르지 않고 `std.Io.File.stat(io)`의 portable kind를 사용하며
directory·pipe·device를 upload body로 인정하지 않는다. upload body는 pathname을 child가 다시 열게 하지 않고 held fd에서 bounded pipe로 전달한다. closed GitHub request는
`uploads.github.com/repos/ohah/maru/releases/<exact-id>/assets?name=<derived-name>`와 octet-stream body만 허용하며 각 response의
nonzero asset ID, exact name/size/SHA-256 digest, octet-stream content type와 uploaded state를 strict JSON으로 다시 결속한다.

순서는 DMG→frozen executable→evidence→manifest로 고정한다. 모든 호출은 shared deadline의 fresh remaining, pinned CLI와 전체 typed
graph 재검증으로 둘러싸며 네 response가 모두 맞은 뒤에만 `DraftAssets`를 게시한다. 첫 remote mutation 뒤의 timeout, child failure,
malformed/foreign response, local allocation 또는 publication 실패는 `.empty`로 되돌아가거나 자동 retry·기존 asset 재사용·삭제를 하지
않는다. 결속된 asset ID 목록이 있으면 terminal cleanup-required audit state에 보존하고, 성공 여부를 확정할 수 없는 호출이 하나라도
있으면 terminal remote-state-unknown으로 보존해 사람이 exact draft를 감사해야 한다. copied/pre-owned owner, inode/path/manifest/receipt
drift, duplicate name/ID, partial attach와 기존 remote asset은 publication 0이다. focused gate는 exact request/body order, held-fd streaming,
전 fail-index terminal state, token staging zeroization과 bounded response ownership을 Debug·ReleaseFast에서 검증한다. 이 component는 draft redownload validation,
publish, post-publish release attestation, live workflow wiring 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.34 exact draft asset redownload 권위

upload response는 GitHub가 실제로 보존한 bytes의 증거가 아니므로 draft publish 전에 네 asset을 exact asset ID로 다시 내려받아
held 원본과 대조한다. `release_adapter_github_draft_asset_redownload.zig`의 final-address move-only
`RedownloadValidation`만 ready `DraftAuthority`와 `DraftAssets`, candidate/authored attestation, canonical held manifest와 네 held file,
checkout 전에 고정한 GitHub CLI, validated token 및 같은 release phase `Deadline`을 함께 소비한다. caller는 release/tag/name/SHA,
asset 순서, 성공 bool 또는 download URL을 별도 scalar로 제출하지 않는다.

각 요청은 `github.com/repos/ohah/maru/releases/assets/<exact-asset-id>`에 octet-stream accept header를 사용하며
DMG→frozen executable→evidence→manifest 순서로만 실행한다. response body는 pathname이나 unbounded heap/file로 materialize하지 않고
bounded pipe에서 chunk별로 SHA-256과 byte count를 계산한다. expected size를 넘는 첫 byte, 조기 EOF, child failure·timeout 또는 digest
불일치는 즉시 실패한다. stderr는 protocol bytes와 섞지 않고 token은 argv나 inherited environment에 두지 않는다. 각 child 전후에는
DraftAuthority, DraftAssets, pinned CLI, 네 held file과 typed attestation graph를 모두 재검증하고 최초 fixed snapshot과 비교한다.

네 exact ID/name/size/SHA가 모두 원본과 일치하고 마지막 fresh deadline·authority fence를 통과한 뒤에만 validation owner를 게시한다.
copied/pre-owned/aliased result, duplicate/zero asset ID, held inode/path/manifest/receipt drift, foreign capture, partial redownload와 allocator
failure는 publication 0이다. redownload는 remote mutation이 아니므로 실패가 draft cleanup state를 바꾸거나 attach를 재시도·삭제하지
않는다. focused gate는 exact argv/environment/order, streaming count/digest cap, 전 child-index와 authority drift를 Debug·ReleaseFast에서
검증하며 최초·각 child 전후·최종 authority snapshot의 모든 allocation fail index에서 publication 0을 고정한다. 이 component는 draft
publish, post-publish release attestation, live workflow wiring 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.35 exact draft publication 권위

draft 공개 전환은 tag나 latest lookup이 아니라 ready `DraftAuthority.id` 하나에 대한 단일 PATCH mutation으로만 수행한다.
`release_adapter_github_draft_publication.zig`의 final-address move-only `PublishedRelease`가 attachment 권위 graph와 ready
`DraftAssets`, ready `RedownloadValidation`, checkout 전에 고정한 GitHub CLI, validated token 및 같은 release phase `Deadline`을
함께 소비한다. caller는 release ID/tag/source, asset 집합, draft/prerelease/immutable 판정 또는 성공 bool을 별도 scalar로 제출하지 않는다.

mutation 직전에는 attachment graph를 다시 만들고 redownload receipt의 release/asset ID가 같은 fixed snapshot을 가리키는지 확인한다.
closed request는 `github.com/repos/ohah/maru/releases/<exact-id>`에 `draft=false`, `prerelease=false`만 보내며 clobber, asset mutation,
release note/title/tag/source 수정 필드는 허용하지 않는다. child가 시작된 뒤에는 timeout, child failure, malformed response와 local
allocation failure 어느 것도 `.empty`로 되돌아가 자동 PATCH 재시도를 허용하지 않는다. 성공 여부를 모르면
remote-state-unknown, exact published response까지 알았지만 마지막 local publication이 실패하면 cleanup-required audit state다.

response는 exact ID/tag/source, `draft=false`, `prerelease=false`, explicit immutable release와 네 asset의 exact ID/name/size,
uploaded state, SHA-256 digest 및 octet-stream content type을 strict JSON으로 결속한다. 누락·추가·duplicate/foreign asset이나
redownload 이후 asset 교환은 published authority가 아니다. 마지막 fresh deadline과 attachment/redownload/CLI fence 뒤에만
`PublishedRelease`를 게시한다. copied/pre-owned result, duplicate asset authority, authority drift, mutation 전 두 authority snapshot과
응답 후 authority snapshot의 allocation failure, 전 child/parser allocation fail-index를 Debug·ReleaseFast에서 검증한다. 앞의 두
snapshot failure는 mutation 0과 `.empty`, 응답 뒤 snapshot failure는 exact release ID를 보존한 `.cleanup_required`여야 한다. 이
component는 post-publish release attestation, live workflow wiring 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.36 published release attestation 권위

공개 직후 검증은 published tag를 다시 검색하거나 caller가 release/asset scalar를 재제출하는 경로가 아니다.
`release_adapter_github_post_publish_attestation.zig`의 final-address move-only `VerifiedRelease`가 ready
`PublishedRelease`, 그 publication이 소비한 ready `DraftAssets`·`RedownloadValidation`과 attachment 권위 graph, checkout 전에 고정한 GitHub CLI, validated token과 같은
release phase `Deadline`을 함께 소비한다. authority snapshot은 canonical manifest의 repository/release/source와 manifest가
열거한 세 asset, held manifest 자체의 name/size/SHA-256, published release ID/tag/source 및 네 asset ID를 한 번에 다시 유도한다.

owner는 GitHub tag ref와 최대 8개의 annotated tag chain을 기존 bounded resolver로 읽어 manifest source commit까지 수렴시키고,
그 첫 ref target을 release attestation의 `tag_ref_sha`와 별도로 결속한다. 이어 exact `release verify` 한 번과 DMG, frozen executable,
evidence, manifest 순서의 exact `release verify-asset` 네 번을 수행한다. 각 child 직전과 직후에는 CLI, held inode와 전체 publication
graph를 다시 검증하며 모든 호출은 같은 absolute monotonic deadline을 소비한다. release/asset statement는 모두 exact release
ID/tag/tag-ref와 공개 시점 네 asset name/SHA-256 집합을 가져야 한다. lightweight tag의 ref SHA와 source commit이 우연히 같다는
가정은 하지 않는다.

모든 tag-chain/release/asset 검증과 마지막 fresh authority fence가 끝난 뒤에만 exact 네 asset ID/SHA-256을 소유한 `VerifiedRelease`를 게시한다. copied/pre-owned/aliased
result, pathname·inode·mode·link-count·digest drift, publish authority 교환, foreign capture, child/timeout/allocation failure는 결과
publication 0이다. 공개 자체는 이미 끝났으므로 실패를 draft cleanup이나 publish 재시도로 바꾸지 않고 audit 실패로 남긴다.
focused gate `test-session-host-release-adapter-post-publish-attestation`은 exact 순서, shared deadline, tag-ref/source 분리, 매 child
전후 authority fence, owner/alias/drift와 전 child/authority allocation fail-index를 Debug·ReleaseFast typed composition에서 검증한다.
held inode의 actual filesystem 재검증은 이 owner가 매 snapshot마다 호출하는 `test-session-host-release-adapter-draft-assets`가 별도로 소유한다.
이 component는 live workflow wiring 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.37 candidate publication transaction 권위

candidate evidence가 게시된 뒤의 release mutation 순서는 leaf caller들의 관례가 아니라
`release_adapter_candidate_publication_phase.zig`의 caller-owned final-address `Publication` lifecycle 하나가 소유한다. 이 owner는 같은
release phase `Deadline`을 빌려 candidate manifest authoring→evidence/manifest artifact attestation→exact draft asset
attachment→exact-ID redownload validation→draft publication→post-publish release attestation을 정확히 이 순서로 한 번씩 실행한다.
caller는 중간 owner, release/asset ID, 단계별 deadline·성공 bool 또는 cleanup 대상을 제출하거나 일부 단계만 꺼내 재호출하지 않는다.

generic preflight는 pristine final-address lifecycle과 borrowed deadline identity를 첫 leaf 전에 검사하고, step implementation이 내놓은
bounded canonical authority bytes가 publication storage와 겹치지 않는지 확인한다. transaction 자신이 그 bytes에서 길이와 domain을
구분한 BLAKE3 audit seal을 유도해 32-byte inline storage에 복사하며 이후 borrowed slice나 pointer를 audit state로 보존하지 않는다.
후속 production owner는 manifest/authored-attestation/attachment/redownload/published/verified concrete storage의 pairwise alias와
deadline 및 모든 borrowed authority/path storage alias를 이 preflight callback 안에서 닫고, draft,
candidate/product/source/compatibility, held DMG·frozen executable·evidence, pinned CLI와 manifest output pathname을 canonical authority
bytes로 제공해야 한다. 각 leaf 앞뒤와 최종 publication 직전에는 production owner가 같은 graph에서 다시 유도한 seal이 bytewise exact인지와
같은 deadline의 fresh remaining을 다시 확인한다. transaction은 새 시작 시각·expiry를 만들거나 앞서 읽은 remaining을 다음 leaf의
budget으로 재사용하지 않는다.

manifest부터 redownload까지의 mutation 전 실패는 이미 열린 local owner를 verified→published→redownload→attachment→authored
attestation→manifest 역순으로 best-effort cleanup한다. attach가 첫 remote mutation을 시작했거나 publish가 시작된 뒤의
`remote-state-unknown`·`cleanup-required`는 empty로 되돌리거나 자동 retry·asset 삭제·draft 재생성으로 성공을 합성하지 않는다.
terminal remote state와 exact known ID 및 preflight에서 유도한 fixed audit seal은 `Publication`에 보존하고 workflow를
audit-required로 끝낸다. publish가 ready가 된 뒤
post-publish attestation이 실패해도 공개 release를 재게시·변경하지 않으며 published authority와 실패 단계를 보존한다. cleanup 실패는
원래 오류보다 `CleanupFailed`가 우선하고 아직 live인 exact owner만 남겨 `retryCleanup`이 같은 역순으로 재시도한다. remote terminal
state는 cleanup retry 대상이 아니며 사람이 감사하기 전 같은 publication owner를 재사용할 수 없다.

성공은 `VerifiedRelease`를 포함한 complete publication owner로만 게시한다. 성공 owner의 명시적 cleanup은 verified receipt부터
manifest까지 역순으로 local capability를 닫되 remote release나 asset을 삭제하지 않는다. focused gate
`test-session-host-release-adapter-candidate-publication-phase`는 exact 순서·same-deadline identity, no-side-effect preflight,
각 leaf fail-index, reverse cleanup과 partial-cleanup retry, attach/publish terminal-state 비재시도, publish 뒤 attestation 실패 보존,
copied/pre-owned/alias/drift를 Debug·ReleaseFast에서 검증한다. 각 leaf의 GitHub command·filesystem·semantic 의미는 기존 focused gate가
계속 소유한다. concrete leaf storage·authority-byte derivation과 alias matrix는 후속 production wiring gate가 소유한다. 이 transaction은
production argument/bootstrap 배선, `.github/workflows/release.yml` 호출 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.38 candidate publication production owner

`release_adapter_candidate_publication_product.zig`의 caller-owned final-address `Execution`은 §11.37 transaction과
candidate manifest `PinnedReleaseFile`, `AuthoredAttestation`, `DraftAssets`, `RedownloadValidation`, `PublishedRelease`,
`VerifiedRelease` concrete owner를 한 주소에 둔다. production `run`만 manifest authoring, authored artifact attestation,
exact draft attachment, exact-ID redownload, draft publication과 post-publish attestation leaf를 §11.37 순서로 호출한다.
caller는 중간 owner, release/asset ID, 단계별 success 또는 cleanup 대상을 제출하지 않는다.

preflight는 pristine nested owner와 하나의 final-address `Deadline`, 모든 input/output/buffer/path의 pairwise non-alias,
positive budget, ready draft와 held candidate/evidence/CLI 권위를 remote mutation 전에 검증한다. 최초 audit snapshot은 candidate
manifest authority가 재유도한 canonical manifest bytes에 protected context, ready draft ID, pinned CLI identity·mode·size·path/digest, 기존
DMG·frozen executable·evidence 세 held file의 identity·mode·size·digest, manifest output을 포함한 exact absolute pathname을 길이
구분해 결속한다. 아직 쓰이지 않은 manifest inode를 최초 snapshot에 있었다고 주장하지 않는다. snapshot backing은 `Execution`이나
caller storage를 빌리지 않으며 §11.37 transaction이 seal을 복사한 직후 폐기한다. 각 authority fence는 같은 typed graph에서
expected canonical bytes와 기존 세 held file을 다시 유도하고, manifest 작성 뒤에는 새 held manifest가 그 bytes/output pathname과
exact하게 결속되는지도 확인한 다음 transaction의 domain-separated seal과 bytewise exact로 대조한다. 모든 fence는 같은 borrowed
deadline의 fresh remaining을 소비한다.

production owner는 호출 동안만 context, typed authority pointer, pathname, token과 response buffer를 빌리고 성공·실패 반환 전에
그 borrow를 모두 제거한다. 성공 시 deadline과 audit scratch도 닫고 six concrete owner와 complete `Publication`만 남긴다.
명시적 cleanup은 verified→published→redownload→attachment→authored→manifest 역순이며 remote release나 asset을 삭제하지 않는다.
remote mutation 전 leaf 실패와 cleanup 실패는 §11.37의 exact retry set을 보존한다. attachment가
`remote_state_unknown|cleanup_required`가 됐거나 publication이 시작된 뒤에는 concrete terminal owner와 audit stage를 보존하고
automatic cleanup/retry를 제공하지 않는다.

focused gate `test-session-host-release-adapter-candidate-publication-product`는 production leaf callsite가 각각 하나뿐임,
single deadline과 final-address/copy/alias 차단을 Debug·ReleaseFast에서 검증한다. canonical audit 재유도, borrow 제거,
성공 concrete owner 집합, 역순 cleanup과 partial cleanup retry, attachment/publish/post-publish terminal 보존은 §11.37 transaction 및
각 leaf의 기존 gate가 계속 소유하며, 실제 GitHub child 성공도 각 leaf의 product gate가 검증한다. 이 단계는 executable bootstrap/argument parser와
`.github/workflows/release.yml` 호출 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.39 candidate publication prerequisite transaction 권위

candidate publication에 필요한 typed graph를 workflow shell이 단계별 성공 boolean이나 scalar로 조립하지 않는다.
`release_adapter_candidate_prerequisite_phase.zig`의 caller-owned final-address `Preparation` lifecycle 하나가 같은 release phase
`Deadline` 아래 candidate artifact attestation→draft creation→`CandidateFiles` 결속→Apple product 관측→source tree 관측→
candidate evidence identity 조립→compatibility probe를 정확히 이 순서로 한 번씩 실행한다. caller는 중간 owner, draft/release ID,
candidate digest, source tree, signing observation, compatibility 값이나 단계별 deadline을 제출하거나 일부 단계만 재호출하지 않는다.

preflight는 pristine lifecycle과 borrowed deadline identity를 첫 leaf 전에 검증한다. 각 leaf 앞뒤에는 production owner가 candidate
pathname, pinned CLI, protected context와 지금까지 생긴 typed owner graph를 다시 검증하고 같은 deadline의 fresh remaining을
확인한다. transaction은 새 expiry를 만들거나 이전 remaining을 다음 child budget으로 재사용하지 않는다. `CandidateFiles`처럼
allocation 없는 결속 단계도 전후 authority fence에서 제외하지 않는다. 모든 단계가 끝난 뒤 마지막 authority/deadline fence를
통과한 경우에만 complete prerequisite owner를 게시한다.

draft mutation이 시작되기 전 실패는 열린 local owner를 compatibility→identity→source→product→files→attestation 역순으로
best-effort cleanup한다. draft child가 시작된 뒤에는 실패가 remote state를 `.empty`로 되돌리거나 draft 생성 자동 retry·삭제를
허용하지 않는다. exact draft ID를 아는 `cleanup_required`, 결과를 모르는 `remote_state_unknown`, ready draft 뒤 후속 local 실패를
각각 terminal audit state로 보존한다. 이때 이미 열린 local owner는 audit graph를 재검증하는 데 필요한 동안 보존하며 ordinary
`retryCleanup` 대상으로 축소하지 않는다. 성공 owner의 명시적 cleanup은 local capability를 역순으로 닫되 remote draft를
삭제하지 않는다.

focused gate `test-session-host-release-adapter-candidate-prerequisite-phase`는 preflight 선행, exact step order와 same-deadline
identity, 각 leaf fail-index, mutation 전 reverse cleanup과 partial-cleanup retry, draft의 unknown/known/ready terminal 보존,
각 authority fence와 최종 publication을 Debug·ReleaseFast에서 검증한다. concrete leaf storage·alias matrix와 실제 production
callsite는 후속 product wiring gate가 소유한다. 이 transaction은 baseline/upgrade evidence 실행, candidate publication,
executable bootstrap 배선, live release workflow 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

### 11.40 candidate publication prerequisite product owner

`release_adapter_candidate_prerequisite_product.zig`의 caller-owned final-address `Execution` 하나가 §11.39
`Preparation`, 하나의 `Deadline`, `CandidateAttestation`, `DraftAuthority`, `CandidateFiles`, `CandidateProduct`,
`SourceTreeAuthority`, `CandidateEvidenceIdentity`, `CandidateCompatibility`와 Apple command capture storage를 직접 소유한다.
production `run`의 caller는 protected `Context`, test UUID, candidate/DMG work absolute pathname, pinned GitHub CLI, token,
하나의 bounded scratch buffer와 positive budget만 제공한다. caller는 중간 typed owner, draft ID, digest, signing 관측,
source tree, compatibility 값, Apple capture storage 또는 child별 budget/deadline을 주입하지 않는다.

첫 leaf 전 preflight는 `Execution`과 모든 nested owner가 pristine이고 final address에 있으며 budget이 양수인지 검증한다.
서로 다른 nested owner의 storage region은 겹치지 않고, top-level `Execution` 및 그 내부 region은 pinned CLI, context scalar,
UUID, pathname, token, caller scratch buffer와 빈 slice를 제외하고 겹치지 않아야 한다. 내부 Apple capture storage는 caller에게
노출하거나 authority로 게시하지 않고 해당 관측에서만 덮어쓴다. candidate pathname은 각 leaf의 basename/absolute-path 계약을 만족하고 DMG work path는 기존 파일과
부모가 겹치지 않아야 한다. 이 full alias/path matrix와 pinned CLI 재검증은 remote draft 생성 전에 실패해야 하며, 검증 실패는
GitHub·filesystem·Apple leaf를 한 번도 호출하지 않는다.

concrete steps는 candidate attestation, GitHub draft creation, `CandidateFiles.observe`, `CandidateProduct.observe`,
`SourceTreeAuthority.observe`, `CandidateEvidenceIdentity.compose`, `CandidateCompatibility.composeUntil` production leaf를 각각
정확히 한 callsite에서 §11.39 순서로 호출한다. deadline을 소비하지 않는 결속 leaf 전후에도 같은 `Deadline`의 fresh
`remaining`과 전체 typed graph를 다시 검증한다. authority fence는 protected context, pinned CLI, candidate paths와 지금까지
게시된 owner를 그 owner의 typed revalidation API로 다시 유도하며 scalar나 boolean 사본을 권위로 사용하지 않는다.

반환 전에는 성공, mutation 전 실패, cleanup 실패, terminal audit 실패 모두 caller의 context/path/UUID/token/scratch borrow를
제거하고 token을 복사하지 않으며 `Deadline`을 닫는다. 성공은 complete `Preparation`과 self-owned concrete owner 일곱 개만
게시한다. 명시적 cleanup은 compatibility→identity→source→product→files→draft→attestation 역순으로 local capability를 닫고
remote draft를 삭제하지 않는다. mutation 전 cleanup 일부가 실패하면 exact remaining owner만 `retryCleanup` 대상으로 남긴다.
draft가 `remote_state_unknown|cleanup_required|ready`가 된 뒤의 어느 실패도 ordinary cleanup/retry로 축소하지 않고 exact
`AuditStage`, draft 상태와 당시까지 게시된 concrete owner를 final-address `Execution` 안에 보존한다.

focused gate `test-session-host-release-adapter-candidate-prerequisite-product`는 production leaf callsite 각각 하나, single deadline,
pristine/final-address/copy 차단, full pairwise alias·path·buffer preflight, leaf별 typed fence, borrow/deadline scrubbing, 성공 owner 집합,
역순 cleanup과 partial-cleanup retry, draft unknown/known/ready terminal graph 보존을 Debug·ReleaseFast에서 검증한다. 실제 GitHub와
Apple child 동작은 각 leaf product gate가 계속 소유한다. 이 단계는 baseline/upgrade evidence 실행, candidate publication,
executable bootstrap 배선, live release workflow 또는 frozen signed U5 제품 E2E를 완료하지 않는다.

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
