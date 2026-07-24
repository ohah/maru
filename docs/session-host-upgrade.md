# Session host 실행 중 업그레이드

이 문서는 앱 업데이트 뒤에도 이미 살아 있는 terminal runtime의 PTY·자식 프로세스·`TerminalCore`를 유지한 채
`maru-sessiond` binary를 교체하는 계약의 단일 출처다. 일반 attach·runtime 소유권은
[영속 터미널 세션 호스트](persistent-session-host.md), workspace의 `runtime-handle` 저장은
[Workspace Restore](workspace-restore.md), 화면 전송 codec은 `maru.screen-stream` 계약을 따른다.

> **상태: U0 완료, U1 codec·U2 quiesce 핵심 구현과 U3 same-PID exec·rollback 검증 행렬 구현 중.
> U1/U2의 §11 전체 종료 gate는 아직 열려 있고 제품 업그레이드는 비활성이다.**
> 현재 살아 있는 host가 `host_exec_upgrade_v1`을 광고하지 않으면 새 앱은 그 host를 실행 중 교체할 수 없다.
> 이 경우 지원하는 N-1 MRSH adapter로 attach해 기존 runtime을 그대로 쓰거나, attachment가 모두 끝난 뒤 구 host를
> 계속 drain한다. **attachment가 0이어도 runtime이 하나라도 살아 있으면 구 host를 종료하지 않으며, runtime count가
> 0이 된 뒤에만** 자연 종료하고 새 host를 시작한다. capability 없는 host를 죽여 migration처럼 보이게 하지 않는다.

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

host는 target path를 검증만 하고 나중에 다시 열지 않는다. no-follow로 연 fd의 type/UID를 확인하고 owner-only attempt
directory에 `O_EXCL`로 복사·sync·rename·directory sync한 **staged target inode**의 hash/build identity를 검증한 뒤
그 image만 실행한다. exec 직전 staged inode/path identity를 다시 확인하며 validation→exec 사이 target swap
failure injection을 둔다.

성공 응답은 `{attempt_id,state:"accepted"}`이고 반드시 `reply_and_close`로 client에 전량 쓴 뒤 request fd를 닫는다.
실제 quiesce/exec는 connection handler가 아니라 daemon-owned pending attempt가 fd close를 관측한 뒤 시작한다.
같은 `attempt_id`와 같은 target identity 재요청은 같은 결과를 돌려주며, 같은 ID의 다른 target은
`attempt_conflict`다. accepted는 upgrade 성공을 뜻하지 않는다.

`host.upgrade.status {attempt_id}`는 `pending | resumed | rolled_back | committed | failed_nonretryable`와 typed reason을
돌려준다. client의 성공 판정은 EOF가 아니라 재접속한 `host.info`의 **같은 `host_id`**, target build/protocol,
증가한 `upgrade_epoch`, exact runtime ID 집합이다. `resumed`/`rolled_back`은 원 target으로 자동 재시도하지 않으며
명시적 새 attempt ID가 필요하다.

## 4. 권위와 저장 위치

- 실행 중 권위는 계속 host memory의 `TerminalRuntimeRegistry`와 각 runtime의 `TerminalCore`·`LivePtySession`이다.
- workspace manifest는 `host_id:runtime_id` binding만 가진다. handoff bytes나 PTY fd 번호를 저장하지 않는다.
- handoff는 session-host owner-only runtime directory 아래 attempt별 임시 파일에 쓴다. `0600`, regular file,
  same-UID, no-follow를 검증하고 write→sync→atomic rename 뒤에만 committed로 본다.
- staged rollback executable은 **upgrade 요청 때가 아니라 upgrade-capable host 시작 시점**에 owner-only host
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
- 성공 commit 뒤 staged target을 **새 current rollback self-image로 atomic promote**하고 directory sync한다.
  그 성공 뒤에만 이전 self-image를 삭제한다. promotion 실패면 새 host는 계속 serve하지만
  `host_exec_upgrade_v1` 광고를 즉시 내리고 다음 live upgrade를 금지한다. rollback self-image는 host lifetime
  동안 유지하고 정상 host 종료 때 삭제한다. 다음 host 시작은 owner-only directory의 non-secret stale attempt
  metadata와 staged target 잔해를 no-follow identity 검증 뒤 정리한다.

fd 번호는 durable identity가 아니다. handoff manifest의 runtime record가 inherited fd slot을 가리키고, 새 process가
실제 open fd의 type/flags를 다시 검증한 뒤 새 `PtySession`에 결합한다.

## 5. 상태 머신

```text
serving
  -> preflight
  -> admission_closed
  -> quiescing
  -> handoff_committed
  -> exec_pending
  -> restoring
  -> restore_validated
  -> restore_prepared
  -> committed
  -> serving
```

실패 전이는 다음처럼 고정한다.

| 실패 지점 | 결과 |
| --- | --- |
| preflight | 아무 상태도 바꾸지 않고 구 host가 계속 serve |
| admission close 전 | 구 host가 계속 serve |
| quiesce/flush deadline | reader·admission을 재개하고 임시 파일 제거 |
| handoff write/sync/rename | CLOEXEC를 건드리지 않고 구 host 재개 |
| `exec` syscall 실패 | inherited flag를 원복하고 구 host 재개 |
| target entrypoint가 rollback handler를 설치한 뒤 pre-commit target-only invariant/OOM 실패 | PTY read/write/thread 시작 없이 검증된 backup fd로 staged 구 binary exec rollback |
| restore commit 뒤 host failure | host crash와 동일하며 v1 복구 범위 밖 |

한 attempt에는 opaque idempotency key와 최대 rollback 횟수 1을 둔다. rollback binary가 같은 failed target을 다시
자동 실행하지 않도록 argv와 manifest에 rollback 원인을 기록한다.

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
- spawn/terminate/resize/attach request가 처리 중이지 않다.
- target executable이 same-UID regular file이고 허용된 Maru build identity를 가진다.
- host 시작 때 보존한 staged rollback self-image가 존재하고 recorded hash와 일치한다.
- target reader가 writer handoff schema와 runtime field set을 지원한다.
- handoff·rollback staging에 필요한 bounded disk space와 fd budget이 확보됐다.
- host 전체가 한 번에 옮겨진다. runtime 일부만 성공시키는 mixed-version host는 만들지 않는다.

GUI 재실행이 업그레이드를 유발할 때는 runtime attach보다 upgrade preflight를 먼저 한다. `upgrade_busy`면 current/N-1
adapter로 정상 attach하고, 마지막 attachment가 떨어진 뒤 다시 시도한다. 사용자 입력을 끊어서 업그레이드를 강행하지 않는다.

## 7. Quiesce 계약

현재 reader의 stack-local response buffer와 실행 중 queue operation은 그대로는 직렬화할 수 없다. U2에서 reader의
in-flight 상태를 명시적 owned transfer state로 옮긴 뒤 다음 barrier를 구현한다.

1. 새 connection/frame admission을 닫는다.
2. attachment 0을 다시 확인한다.
3. 이미 admission된 input bytes와 core command를 fence 순서대로 PTY에 전량 쓴다.
4. core가 만든 PTY response도 전량 쓴다. deadline 안에 flush되지 않으면 upgrade를 취소한다.
5. reader는 한 poll iteration 경계에서 멈춘다. local read buffer에 처리되지 않은 bytes가 없어야 한다. 현재
   `stopAndJoin`은 child를 종료하므로 사용할 수 없고, U2가 child/fd/queue를 닫지 않는 별도 pause→safe-point→join
   primitive를 먼저 추가한다.
6. 모든 `PtySession`의 `exited/closing/reaping=false`와 event queue empty를 다시 확인한다. quiesce 중 EOF/exit/error가
   생겨 reader가 terminal event를 만들었으면 status를 버리거나 serialize하지 않고 upgrade를 취소해 구 host의 정상
   termination path가 정확히 한 번 소비하게 한다.
7. core lock을 얻어 logical state를 encode한다.
8. PTY kernel buffer에 아직 읽지 않은 output은 그대로 둔다.

admission close부터 old-reader read-back, 두 handoff sync, target preflight, exec 직전까지의 **전체 pause hard
deadline은 5,000ms**다. 어느 하위 단계든 남은 예산 안에 끝나지 않으면 exec하지 않고 reader/admission을 재개한다.
이 예산을 넘는 큰 runtime state는 8 GiB hard cap 안이더라도 live upgrade 대상이 아니며 side-by-side drain을 쓴다.

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
cap과 cap+1, `count × element_size` overflow, section 합계 overflow, allocation OOM-before-mutation을 fixture로 고정한다.

### 반드시 직렬화하는 상태

- `host_id`, runtime IDs, registry size/resize generation, runtime별 canonical grid size.
- `TerminalCore`의 화면·스크롤백·parser/UTF-8/CSI/OSC/DCS/APC 중간 상태와 모든 logical mode.
- link/grapheme/kitty image storage와 cell이 참조하는 stable ID 관계.
- cwd/title/SSH destination/semantic state와 generation counter.
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
- connection, stream ID, controller/observer attachment. v1 precondition상 모두 비어 있다.
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
  decode/validation/allocation, listener 준비, paused-thread 생성이 끝나기 전에는 master fd를 read/write/resize하지 않는다.
- inherited allowlist slot은 target→staged-old rollback exec가 가능하도록 `committed` 직전까지 `CLOEXEC`를 다시
  켜지 않는다. rollback binary가 restore할 때도 같은 규칙을 지킨다.
- `committed`는 모든 runtime과 listener가 준비된 뒤 paused reader release 직전의 단 하나의 irreversible point다.
  commit에서 PTY master slot과 lifetime owner-lock slot에 `CLOEXEC`를 복구하고 primary/backup handoff slot은
  닫는다. 필요하면 owner-lock을 CLOEXEC duplicate로 adopt한 뒤 inherited slot을 닫는다. 그 다음 reader들을
  release한다. 이 cleanup 뒤 fd 3 이상 non-CLOEXEC 집합은 비어 있어 다음 upgrade preflight의 “모든 fd CLOEXEC”
  전제가 다시 성립해야 한다. 그 뒤 host registry manifest를 새
  protocol/build/upgrade epoch와 `ready` lifecycle로 atomic republish하고 admission을 연다. rollback은 구
  protocol/build identity와 lifecycle을 대칭적으로 republish한다. 첫 PTY
  read/write/resize, child reap, 외부 accept 중 하나라도 일어난 뒤에는 rollback하지 않는다.
- `dup`/fd flag 설정 또는 `exec` syscall 자체가 실패해 old image가 재개될 때도 discovery manifest를 old
  protocol/build/upgrade epoch와 `ready` lifecycle로 atomic republish한 뒤 admission을 연다.
- target validation 실패 뒤 staged-old rollback `exec` syscall 자체도 실패하면 재귀 재시도하지 않고
  `rollback_exec_failed` fail-stop으로 끝낸다. 이 이중 실행 실패는 runtime 보존 보장 범위 밖이며 구조화 artifact만 남긴다.
- `waitpid`는 같은 PID host가 계속 소유한다. 별도 process가 같은 child를 reap하지 않는다.

## 10. 멀티윈도우·Quick Terminal·SSH

- 같은 app process의 여러 Window는 app-global host connection을 공유한다. 정상 Quit 뒤 connection이 없어졌을 때만
  upgrade하므로 Window 수는 handoff 조건에 영향을 주지 않는다.
- 다른 Maru app process가 붙어 있으면 active attachment이므로 upgrade를 미룬다.
- workspace마다 저장된 `host_id:runtime_id`가 유지돼 재실행 뒤 각 Term이 원래 runtime에 다시 붙는다.
- Quick Terminal은 현재 명시적으로 in-process라 이 upgrade 대상이 아니다. Quick이 host-backed로 전환되는 별도 결정 전에는
  앱 Quit 때 종료되는 기존 계약을 유지한다.
- SSH에서 실행한 `maru attach`도 동일 UID observer/controller다. 붙어 있으면 upgrade를 미루고 연결을 강제로 끊지 않는다.

## 11. 단계와 종료 gate

### U0 — 소유 필드 inventory와 문서

- 모든 handoff 관련 owner type의 필드가 `serialized`·`reconstructed`·`inherited_resource`·`must_be_empty` 중
  정확히 하나로 분류된다.
- 새 필드가 미분류되거나 중복 분류되면 `test-session-host` compile이 실패한다.
- 제품 command/capability는 추가하지 않는다.
- U0 종료 때 side-by-side drain 대비 실제 사용자 가치, state 크기/시간 예산, codec 장기 유지비를 다시 검토한다.
  U0 통과만으로 U1 착수나 제품 migration 가능성을 승인하지 않는다.

### U1 — 순수 handoff codec

- bounded envelope/section/TLV codec과 current state DTO를 구현한다.
- 모든 logical state의 round-trip, malformed/duplicate/unknown-required/cap/checksum/OOM을 자동 검증한다.
- partial UTF-8와 각 parser state fixture를 별도 포함한다.
- **구현됨:** stable explicit tag의 `maru.host-handoff.v1`, host/runtime DTO, host-wide atomic decode,
  runtime identity/child/geometry/fd slot과 complete `TerminalCore` round-trip을 `test-session-host`가 검증한다.
  fail-every-allocation은 부분 candidate를 publish하거나 누수하지 않는다.

### U2 — quiesce/resume

- reader owned transfer state와 admission barrier를 구현한다.
- host가 attachment 0에서도 `PtyEventQueue`의 exit/read-error를 exact-once로 소비해 process state와 registry
  lifecycle을 전진시키는 owner drain을 구현한다. quiesce 중 child exit로 abort한 뒤 이 drain이 status를 한 번
  소비하고 같은 dead runtime 때문에 upgrade retry가 영구 abort하지 않는지 검증한다.
- quiesce 성공·deadline·queue full·continuous output·response pending 실패 주입에서 byte 순서와 재개를 검증한다.
- 아직 `exec`하지 않고 같은 process에서 quiesce→encode→resume한다.
- **구현됨:** socket frame admission gate, attachment/lifecycle 재검사, reader-owned response state,
  비파괴 pause/join/resume, GUI attachment 0의 owner event drain, 5초 hard-deadline coordinator를 연결했다.
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
  검증한다. 다만 old fixture가 현재 native 모듈과 함께 재컴파일되므로 frozen N-1 증거는 아니며, 제품 daemon graph
  commit은 남아 있다.

### U4 — 다중 runtime과 N-1 adapter

- 여러 runtime의 큰 scrollback/kitty/partial parser 상태를 한 attempt로 전량 옮긴다.
- current GUI→frozen N-1 host adapter→upgrade→current attach 제품 경계를 자동화한다.
- 한 runtime decode가 실패하면 어떤 runtime도 commit하지 않는다는 것을 검증한다.
- **구현 중:** connect errno와 handshake/protocol 실패를 typed outcome으로 분리해 endpoint 부재만 launch하고,
  permission/version/malformed peer는 spawn으로 우회하지 않는다. host ID별 heap-pinned client pool이 제품 client를
  직접 소유하고 runtime+host lease를 단일 entry로 묶으며, 제품 AppSession의 new spawn과 workspace capture/restore가
  그 pool을 통하도록 바꿨다. 실제 current daemon 두 개에서 host A/B spawn·exact host ID capture, active A 제거 거부,
  A runtime 종료·host retirement 뒤 B runtime 입력/화면 지속을 process E2E로 검증한다. versioned discovery,
  frozen N-1 wire package/adapter, current+old 동시 workspace restore E2E는 아직 남아 있다.

### U5 — 제품 활성화

- `host_exec_upgrade_v1`과 `host.upgrade.prepare`를 광고한다.
- 앱 재실행 connect 경로가 upgrade 가능/호환 attach/upgrade busy/legacy 불가를 구분해 notice와 구조화 로그를 남긴다.
- signed app update 전후 E2E와 soak가 통과한 뒤에만 자동 upgrade를 기본 활성화한다.

U0~U4가 끝나기 전에는 “구 host session이 새 host로 migration된다”고 제품/PR에 쓰지 않는다.

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
