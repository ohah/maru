# Session host kernel cwd parity 구현 계획

영속 host-backed terminal은 PTY와 자식 프로세스를 `maru-sessiond`가 소유하므로 GUI의
`TermRuntimeBackend.processCwd`가 커널 cwd를 조회할 수 없다. 이 계획은 기존
[영속 세션 호스트 계약](../persistent-session-host.md)의 P3-e4 metadata 경계와
[cwd 2단 규칙](../editor-surface-dock.md)을 바꾸지 않고, 그 조회를 PTY 소유 프로세스로 옮기는 순서를 소유한다.

## 범위와 불변식

- 표시·저장소 판정의 우선순위는 계속 `OSC 7 -> 커널 cwd -> unknown`이다.
- 커널 cwd는 OSC 7 값이 비어 있을 때만 사용한다. 이미 보고된 OSC 7이 오래됐는지를 추측해 덮는 문제는 이 범위가 아니다.
- `ssh_remote_dest`가 있거나 OSC 7 authority host가 로컬이 아니면 로컬 ssh client의 cwd를 원격 cwd로 내보내지 않는다.
- wire는 MRSH v2의 same-major additive 규칙을 따른다. `cwd_host`는 optional string이며, 부재는 기존 동작인 unknown authority다.
- cwd와 cwd_host는 한 observation transaction에서 함께 replace한다. 둘 중 하나만 새 revision으로 게시하지 않는다.
- raw cwd, hostname, argv는 CI artifact나 trace에 기록하지 않는다.
- GUI 프레임 루프가 `proc_pidinfo`를 호출하지 않는다. host의 runtime별 캐시는 monotonic time으로 최대 2 Hz만 조회한다.

## 구현 순서

### K1 - authority model과 wire (완료)

- host `RuntimeObservation`, JSON metadata, owning DTO, immutable preparation/reducer, GUI `RuntimeObservation`에 optional `cwd_host`를 추가한다.
- K1에서는 producer가 빈 authority만 보내 제품 cwd 선택을 바꾸지 않았다. 현재 producer 상태는 K2 절이 소유한다.
- unknown field를 허용하는 same-major 규율과 frozen N-1의 field-absence degradation을 유지한다.
- focused Debug/ReleaseFast wire·ownership·boundary gate가 cwd/cwd_host paired replace, malformed type, cap+1, allocation rollback을 고정한다.

### K2 - host-side kernel sampler (완료)

- `RuntimeManager`가 runtime별 fixed `PATH_MAX` buffer와 monotonic sample time을 소유한다.
- OSC 7 cwd가 비고 SSH destination도 없을 때만 `PtySession.processCwd`를 core lock 밖에서 최대 2 Hz 호출한다.
- 성공한 local fallback은 daemon의 local hostname과 한 쌍으로 observation에 게시한다. 실패·runtime 종료·handle 재사용은 cached pair를 비운다.
- OSC 7 값이 생기면 같은 observation에서 즉시 OSC cwd/cwd_host가 우선하며 kernel cache는 화면에 노출되지 않는다.
- kernel cache의 paired value가 바뀌거나 비워지면 runtime metadata source generation을 올린다. 이 generation은
  `runtime_metadata_sampler.Source`와 change token에 포함되어, core의 OSC/title/foreground가 그대로여도 client가 새 cwd를 받는다.
- eligibility 판정은 core lock 안에서 OSC cwd·SSH destination의 존재만 복사하고 즉시 lock을 놓는다. `processCwd`와
  `gethostname` syscall, cache 비교·갱신은 core lock 밖에서 실행한다.
- 500ms deadline 전의 metadata source preflight는 core lock 없이 기존 generation만 읽는다. 실제 observation을
  materialize할 때는 deadline과 무관하게 eligibility를 다시 확인해 OSC/SSH 전환 중 stale kernel pair를 노출하지 않는다.
  단, 이 재확인은 이미 cache가 있는 runtime의 `processCwd`/`gethostname`을 output materialization에서 다시
  실행하지 않고 500ms metadata cadence에 남겨 slow-observer wake latency와 sampling 소유권을 보존한다.
- hostname은 process-lifetime 상수가 아니므로 sample 성공 때마다 같은 cadence 안에서 다시 읽는다. 조회 실패는
  authority 없는 local로 낮추지 않고 sample 실패로 처리해 cached pair를 비운다.
- 외부 attach의 metadata allocation preflight는 `cwd_host` decoded bytes를 실제 owning DTO와 같은 backing
  footprint에 포함한다. 예약값과 실제 소유값이 갈리면 inbox ledger가 정상 metadata를 invariant failure로 닫으므로,
  Debug/ReleaseFast wire gate가 non-empty authority의 exact byte charge를 고정한다.
- 한 RX aggregate에 metadata와 screen이 같이 들어와 screen payload가 ledger로 이동한 뒤에도 cleanup alias 검증은
  aggregate 주소로 봉인된 `screen_staging` receipt를 인정한다. staged payload range는 현재 소유자인 ledger가 한 번만
  내보내며, intent exporter가 중복 소유하지 않는다. 기존 P5c3d built-product E2E가 이 mixed delta와 이후 입력·stream을 검증한다.

### K3 - 제품 parity gate

- 실제 독립 daemon과 shell-integration 없는 `/bin/bash` 또는 `/bin/sh` runtime에서 `cd` 뒤 cwd/cwd_host가 current client에 도달하는지 검증한다.
- detach 중 `cd` 후 reattach initial metadata가 최신 pair인지, sibling runtime과 cache가 섞이지 않는지 검증한다.
- OSC 7 우선, known SSH destination 억제, remote OSC authority, runtime terminate/handle reuse, frozen N-1 field absence를 교차한다.
- AppSession의 sidebar/display/control-plane 소비자가 기존 `termCwd`/`termCwdForDisplay` 축을 그대로 쓰며 direct metadata 우회가 0인지 boundary로 고정한다.

K1~K3와 전체 `zig build test-session-host`, `mise run check`가 모두 green이기 전에는
host-backed kernel cwd parity 완료를 주장하지 않는다.
