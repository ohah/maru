# 검증 매트릭스

> 응답(report) 축 — DSR/CPR/DA/DECRQM 호스트 응답의 적합성과 vttest 수동 시각 점검은 [VT 적합성 테스트](conformance-testing.md)를 본다.

이 문서는 Maru의 각 영역이 무엇으로 검증되는지 추적하기 위한 표다. 목표는 "나중에 구현하자"가 아니라, 아직 구현되지 않은 영역도 어떤 자동 테스트와 산출물로 증명할지 먼저 정해 두는 것이다.

### 영속 세션 P5 세부 상태

| slice | 상태 | 자동 gate | 환경 의존 gate |
| --- | --- | --- | --- |
| P3-e4d-1 metadata isolation·reattach parity | 구현 완료 | `test-session-host-metadata-reattach-parity`가 별도 실제 daemon·하나의 generation-backed GUI `HostAdapter`·두 forkpty runtime에서 A/B OSC 7/2/5379 event와 screen marker를 서로 격리하고, A detach 중 child가 게시한 최신 full-state가 같은 `host_id:runtime_id`의 다음 `attachExistingWithAdapter` 응답에서 추가 pump 없이 보이는지 Debug·ReleaseFast로 검증한다. trigger와 host가 답한 OSC query marker가 순서를 소유하고, runtime identity·revision·owned cwd/title/SSH 문자열·screen·sibling 불변을 단언한다. boundary gate는 legacy attachment, test-only wire method/제품 분기와 민감한 metadata/argv artifact 기록을 금지한다. | e4d-2a·2b companion gate와 결합해야만 P3-e4d 자동 parity 완료를 증명한다. 실제 AppKit 입력기·픽셀은 별도 수동 범위다. |
| P3-e4d-2a current-host foreground·consumer parity | 구현 완료 | `test-session-host-metadata-consumers`가 별도 실제 daemon·generation-backed GUI connection·forkpty에서 ReleaseFast executable `claude→codex→/bin/cat`을 실제 exec한다. host sampler가 얻은 foreground generation과 OSC 7/5379 revision을 같은 owned observation으로 보내고 AppSession 제품 API의 `pollAgentKinds`, 임시 repository `termGitBranch`, `handleDroppedFiles` 직전 fresh barrier와 SSH upload route가 이를 소비하는지 Debug·ReleaseFast로 검증한다. 존재하지 않는 원격 파일은 upload-start 실패 notice를 내되 local paste/input 0이고, provider·cwd·SSH 제거 뒤 `none`/branch null/destination null로 수렴한다. sampler가 foreground change를 먼저 소비해도 observation cache가 별도 `foreground_generation`을 비교해 stale JSON을 재사용하지 않는다. source boundary는 direct observation/agent/branch 주입, test-only wire·artifact와 fake upload 성공을 금지한다. | e4d-1·2b와 결합해 자동 parity gate를 닫는다. raw cwd·SSH destination·argv·file payload artifact는 남기지 않는다. |
| P3-e4d-2b legacy-binary compatibility | 구현 완료 | `test-session-host-legacy-metadata-consumers`가 historical source commit+봉인 patch로 만든 actual separate-process universal arm64/x86_64 ad-hoc N-1 protocol fixture와 source patch digest를 검증하고, artifact를 제품 hidden host command로 실행한다. current GUI의 exact-manifest `connectExistingHost` hello→generation `HostAdapter`→attach-only `RemoteTermBackend`→`term_ops.createTerm` attach 흐름에서 negotiated metadata `.unsupported`, AppSession observation `.unavailable`, owned cwd/process/SSH empty와 기존 `termGitBranch` null·`pollAgentKinds` none·`remoteUploadContext` null을 Debug·ReleaseFast로 검증한다. source boundary는 current-source legacy mode/capability toggle, direct observation/consumer 주입과 민감한 metadata/argv artifact를 금지한다. | 이 ad-hoc compatibility image는 과거 notarized release 자체였다는 provenance를 주장하지 않는다. kernel cwd fallback과 실제 AppKit 입력기·픽셀도 별도 범위다. |
| P3-e4d-3 actual host-backed SSH upload product E2E | 구현 완료 | `test-session-host-p5d`가 harness-owned localhost `sshd`·실제 OpenSSH ControlMaster·별도 session daemon의 host-owned PTY를 사용한다. 실제 OSC 5379 출력 뒤 공개 file drop/image paste가 managed-generation freshness barrier를 지나고, 원격 dropped 파일 byte equality와 동작 시작 surface의 PTY 화면에 돌아온 절대경로를 함께 단언한다. 이어 닫힌 localhost 포트 목적지의 실제 transport 실패가 worker 결과 큐와 메인 tick을 거쳐 파일·이미지별 전송 실패 notice로 보이고 terminal input/local fallback은 0인지도 고정한다. source boundary는 observation 주입, private apply/pump/upload 직접 호출과 fake ssh 성공을 금지한다. CI의 `session host bundled CLI macOS`가 같은 gate를 매 PR 실행한다. | 재접속 destination 복원과 두 Term destination/control-socket 격리는 P3-e4d-4가 별도 검증한다. harness HOME·key·sshd·ControlMaster·remote bytes는 종료 시 회수되고 민감 payload artifact는 만들지 않는다. |
| P3-e4d-4 reconnect destination·ControlMaster isolation | 구현 완료 | 실제 host runtime A/B가 서로 다른 OSC 5379 destination을 게시하고 detach된 뒤 AppSession 공개 recovered-runtime adoption으로 재접속한다. 새 OSC 없이 attach initial full-state가 각 destination을 복원하고 공개 file/image upload가 실제 A/B ControlMaster와 원래 surface를 선택하는지 검증한다. 두 성공 뒤 A master만 종료하고 harness key를 제거해 B의 기존 socket 성공과 A의 실제 인증 실패 notice·terminal input/local fallback 0을 함께 단언한다. source boundary는 direct observation/restore field 주입, private attach/action/upload drain과 fake SSH를 금지한다. | control path inequality나 `RemoteRuntime.attachExisting` 단위 검증만으로 완료 처리하지 않는다. harness의 manifest/socket/key/control path/remote bytes는 exact 회수하고 민감 destination·payload artifact는 남기지 않는다. |
| CR3a-2c3c control facade | 구현 완료(C1·C2·C3) | `test-session-host-2c3c-c3`가 C1 runtime 7+boundary 1, C2 runtime 5, C3 RemoteRuntime 5+slice-exclusive Client write 1을 Debug·ReleaseFast exact-count로 실행한다. closed projection을 쓰는 blocking generation facade exact 1, generation blocking direct Client/RPC fallback 0, 성공·Unsupported만 dequeue, ResourceExhausted/Busy/hard error retain, blocking drain 단일-owner 재진입 방지, legacy direct call과 recovery resync baseline을 고정한다. 일반 RPC와 detach는 retained queue를 추월하지 않고, terminate OOM만 queue 폐기 뒤 destructive RPC를 허용한다. | Darwin socketpair에서 supported/unsupported wire 0, canonical allocation OOM retain·무독성·exact-once retry, pending progress, close hard-error retain, `input prefix -> control -> input suffix`, input/control OOM 각각의 generation terminate actual RPC와 detach RPC 0을 통과했다. injected write ops는 새 scroll/core frame 각각의 zero·1·len-1·plain full/EINTR과 suffix offset을 결정적으로 실행하고 partial/hard failure의 `outbound_write_ambiguous` fail-close를 고정한다. recovery resync, event, response decoder와 `RemoteRuntime.client` 제거는 이 행의 완료 범위가 아니다. |
| CR3a-2c3d one-shot event facade | C1·C2·C3-1·C3-2 구현 완료, C3-3 confirmed poison primitive·C3-3a1 dormant authority substrate·C3-3a2 dormant final-admission substrate 구현, C3-3a3 product activation·C3-3b1 correlation/ordering migration·C3-3b2a process-seal prerequisite·C3-3b2b0 exact observation·C3-3b2b1 trusted preparation seal·C3-3b2b2 pure preparation recipe·C3-3b2b3 immutable owner preparation·C3-3b3 atomic settlement·C3-3b5 common async close progress·C3-3b4 product semantic commit/pump·C3-3b6 app-quit current/N-1 shutdown·C3-3c product socket/source-zero 구현 완료 | C1은 accepted/unknown admission, binding별 event generation, final-address `EventOwner`, ordinary/idle/`ended_pending` take를 구현했다. C2는 exact-14 facade의 public release, cleanup pin/quarantine, callback closure와 damaged-lease recovery를 구현했다. C3-1은 exact-15 `GenerationAttachment` owner/wrapper와 teardown 합성을, C3-2는 purge-first 제품 drain과 closed pending outcome을 구현했다. C3-3 첫 slice는 exact-15 poison을 registered ClientSlot/node admission과 blocking confirmed effect에 연결했다. C3-3a1은 standalone gate에서 product caller 0인 dormant existing-`EventAuthority` revoke class/derived-cache substrate를 구현했으며 제품 동작은 아직 바꾸지 않는다. a2는 standalone gate에서 product caller 0인 dormant final-admission transaction, a3는 두 substrate를 구현해 product take/release와 현재 존재하는 모든 generation mutation family에 동시에 활성화한다. | 기존 `test-session-host-2c3d-c3-2`와 `test-session-host-2c3d-c3-3`은 각각 C3-2 product drain과 confirmed poison actual socket을 Debug·ReleaseFast로 검증한다. 구현된 a1 gate는 registry runtime 7+boundary 1로 ordinary/unknown class non_revoke_effect, reserved/live/releasing, 정상·corrupt consume, sibling `0→1→2→1→0`, pre-reserve `0→0`, post-reserve abort `0→1→0`, copied registry 거부, same-address generation ABA, typed stale/double settlement delta 0, bounded scan/cache 일치 및 standalone gate 시점의 product take/query caller exact 0을 고정한다. no-fail continuation/recovery replay와 unauthorized underflow subprocess는 a3가 소유한다. a2는 final-admission runtime 7+current-family regression 5+boundary 1로 final-address owner/copy/replay, active self/ownership drift fail-stop, held-owner alias와 두 ownership mode foreign settlement 거부, clear admit+teardown execution lease, queued/injected aggregate+sibling blockers, callback/foreign/active-permit/lease contention, current family error/progress/owner-retention와 standalone gate 시점의 product caller 0을 고정한다. current family는 blocking/nonblocking input, generation control, pending output, 모든 raw `callOrdered` RPC와 nonblocking/RPC resync 두 경로다. transport는 typed `Busy`, RemoteRuntime nonblocking/pending/resync stream은 progress `false`, raw RPC는 `AdminBusy`, observer resize는 success no-op를 유지하며 persistent SSOT의 행별 owner를 보존한다. attach prepared lifecycle은 기존 fence 회귀만 상속하고 future 2c3e typed execute는 signature-only caller 0이다. a1 query와 a2 transaction의 standalone gate는 각각 declaration 1·활성화 전 production caller 0이며, 현재 actual queued+aggregate caller inventory는 a3 boundary가 소유한다. shared pin은 직렬화 근거가 아니며 existing execution lease가 final 검사부터 allocation/offset/syscall까지 소유한다. a3는 product runtime 10+actual-socket 2+boundary 1로 permit→public prepare→registered operation→direct lease→held validate/borrow 뒤 quarantine reserve→pin reserve→generation reserve→quarantine/cleanup bind fault ordinal과 ClientSlot-only held commit wrapper의 Terminal/Corrupt/InvalidPrepared 및 reserve 전 direct-lease Busy가 public prepared abort/reset→operation release→permit abort를 거쳐 `(queue=1,prepared=pristine,aggregate=0,permit/pin/quarantine/reserved-authority=0)`으로 수렴하는지, queue commit 뒤 a1 publish→permit no-fail consume→lease downgrade→transaction consume→operation release의 final stage와 held wrapper exact caller inventory를 검증한다. mint receipt의 sole SSOT는 process-global bounded 4,096-slot registry이며 mutex 아래 O(1) free-stack/direct-slot을 쓴다. row/receipt는 slot index+generation+registry key+final address+Client/operation+PID/process nonce+thread tuple을 exact key로 공유하고 exact consume/abort 뒤 generation을 올려 capacity를 회수한다. canonical mint caller의 `errdefer abortMintReceipt`는 consume 전 실패를 미회수로 남기지 않는다. PID/process nonce/TLS precheck와 mutex 후 PID 재검증은 fork child를 상속 lock/Client graph 전 거부한다. Client는 registry consume 후에만 fence/graph를 읽고 final-address capability body를 완성한다. held API는 raw pointer/public digest/local pin을 금지하고 opaque handle `{slot index,slot generation,private key,publication identity,operation identity}`만 받는다. receipt registry와 별도인 process-private bounded 4,096-slot keyed capability registry가 O(1) free-stack/direct-slot으로 active/closing/readers를 소유한다. 별도 bounded 4,096-slot O(1) reader-pin registry는 final pin address+reader slot/generation/key+capability slot/generation/key canonical row를 먼저 등록한 뒤 readers를 올리고, exact one-shot row consume만 unpin/close owner reader를 내린다. copied/moved/forged/double-unpin/sibling pin은 mutation 0이다. settlement pre-lock은 registry PID/nonce+reader-slot bounds만 읽고 public `pin.fields` authority는 0이다. mutex 안 final-address/reader slot-gen-key row exact consume→canonical cap slot-gen-key materialize→owner process/thread/TLS compare 뒤에만 readers--하며 close drain은 captured canonical cap tuple만 쓴다. OOB/foreign/fork fields tamper는 mutation 0이고 injected reader-capacity exhaustion seam은 out pristine/readers unchanged와 즉시 reuse를 검증한다. capability key는 module-private 256-bit production random secret의 keyed BLAKE3 transcript를 64-bit로 축약한 probabilistic private discriminator다. immediate reuse의 exact ABA authority는 slot generation이며 old/new key inequality 테스트는 관측 oracle이지 absolute collision-free 계약이 아니다. registry pin 뒤에만 private guard에 capability pointer/fence/body를 materialize한다. publish exhaustion은 pristine rollback한다. end는 active→closing→self reader release→readers 0→generation bump/free-slot 뒤 body lifetime을 끝낸다. closing 게시 직후 late pin reject+close wait, same-address immediate reuse, mmap-unmap stale, forged key/fork/replay와 caller/private-registry closure를 고정한다. fault/closing hook은 `builtin.is_test` conditional private storage/API라 설계상 production callable API가 없으며 nm/symbol-zero 검증은 주장하지 않는다. max-terminal issuer, forged/copied/foreign/callback/publication-teardown/fork PoC, deterministic end-vs-reader·consume-vs-abort, abort-capacity 원복·O(1) free-count oracle의 typed reject·mutation 0을 고정한다. Zig build에는 TSAN target이 없어 TSAN coverage를 주장하지 않는다. activation 중 callback reentry·foreign·teardown 거부와 facade별 blocker 결과·owner retention을 검증한다. idle|ended_pending은 payload dereference·transaction/operation/lease/quarantine/pin/a1 0, idle=(prepared pristine, permit consumed), ended_pending=(prepared tombstoned, permit consumed)을 고정한다. target pending offset 0은 free 1/wire 0, partial은 no-retry fail-close, sibling pending은 offset/owner 보존·flush 0 뒤 aggregate zero에서 재개한다. future 2c3e RPC caller 편입은 2c3e gate가 소유한다. C3-3b1은 opaque correlation, canonical capability snapshot, all-event ordering blocker와 queued revoke 뒤 RX-only tail oracle를 구현했다. b1의 internal projection은 substrate이며 dormant semantic handoff는 b2b, 최초 non-test 제품 caller와 pump는 b4가 소유한다. C3-3b2a~b6은 process-seal prerequisite, immutable preparation, atomic settlement, common async close progress, product semantic commit/pump, app-quit current/N-1 shutdown을 b2a→b2b→b3→b5→b4→b6 순서로 소유한다. b2b는 owner당 4-part prepare peak와 3-part published rehash pure budget을, b3는 same-owner Busy 3회 exact-count를, b4는 frame당 `16 * 3 * protocol.max_control_json`과 16-owner round-robin을, b5는 backend-global multi-host runtime cap/cap+1, constant-derived 256 KiB 이하 pointer-free `CloseScanReceipt` 4,096 full scan/stable ticket frozen-max/cursor sweep·`visited*16` selection/relookup·generation+`CloseOperationPin` 검증/최대 16 act 및 authority `ready_remove` 뒤 backend-owned removed 결과를 고정한다. b6는 모든 outcome의 exact target/attempt key, connection-dependent와 post-terminal one-shot connection·GUI-local lease generation·operation·inventory-attempt receipt, pre/post bounded evidence matrix, target당 terminate 3회/app-quit 15초 deadline, non-published noreturn fatal integrity와 monotonic elapsed bucket, backend-neutral fixed-64 FIFO/drop-summary diagnostic DTO와 neutral consumer port만 쓰는 sole app-host bridge의 notice/logger value fan-out과 5개 elapsed 경계 전후를 가진 closed admin outcome, runtime-manifest-only endpoint와 exact artifact/major shutdown profile을 고정한다. 각 slice는 focused Debug·ReleaseFast source-boundary gate를 먼저 통과하고, b5에서 dormant close readiness와 real AppSession synchronous parity를, b4부터 actual product pump와 async `event_pending` tab/window close parity를, b6에서 actual socket host EOF detach/reconnect와 admin ambiguity를 증명해야 한다. 이 gate들이 green이 되기 전에는 C3-3b 구현이나 close parity를 주장하지 않는다. C3-3c는 열린-peer revoked/unknown/semantic failure actual socket과 transport 구현·test fixture를 제외한 `src/**/*.zig` 제품 전체 generation raw `Client` event/effect source-zero를 소유한다. b4는 `RemoteRuntime` generation semantic arm의 focused event/effect allowlist만 0으로 만든다. immediate EOF/unread RX-first와 RPC/decoder direct-call source-zero·cadence/parity는 2c3e 범위이며 그 전에는 2c3 완료를 주장하지 않는다. |
| CR3a-2c3b-3 B3-0 attach execution transaction | 완료(B3-0.1~0.4) | B3-0.4 final-address harness가 actual accepted/EOF/partial-frame, request-prepare 및 독립 alloc·resize ordinal과 13행 전체 제품/strict dispatch를 소유한다. fail-index는 target에서 한 번만 실패한다. 일반 10행은 call-derived `B3Observed`와 cleanup 후 final-zero 전체를 표와 비교하고 issuer 4-case와 두 행은 중립 oracle로 wire byte 0·payload 미관측·cleanup/receipt/allocator final-zero를 공유한다. response publication failure는 payload free exact 1회를 검증하고 teardown은 ReleaseFast에서도 allocator outstanding byte 0과 bounded operation receipt 전수 exact-once 반환을 강제한다. txn/cleanup/expected-stage/completion exact·left/right partial·overflow alias 행렬과 response alias 및 cleanup descriptor/stage·ledger/allocator/guard의 여섯 격리 child가 exact request, canonical free 1, noncanonical/payload free 0과 terminal-before-panic을 검증한다. focused B3 8개+strict 2개+issuer 1개를 Debug·ReleaseFast에서 exact-count하고 order-independent inventory와 public boundary oracle을 강제한다. | Darwin socketpair가 필수이며 비-macOS skip은 완료 증거가 아니다. 이 행만으로 후속 B3-1~B3-6이나 decoder 제품 전환을 증명하지 않으며, B3-1~B3-6은 각 별도 gate로 완료됐다. decoder는 2c3e 후속이다. |
| P5a1a accept hardening | 구현 | Debug/ReleaseFast `zig build test-session-host`가 listener/accepted fd의 명시적 nonblocking+CLOEXEC, empty accept, EINTR→success와 exact retry exhaustion, typed fd pressure와 owner retry/cadence predicate, same-UID 실제 socket, credential-provider seam의 other-UID rejection+peer EOF, frozen N-1/mismatched peer bounded readiness를 검증한다. | 일반 CI는 실제 다른 UID process를 만들 수 없으므로 real cross-UID process rejection은 provisioned runner gate다. P5a1a 당시 public CLI는 미구현이었고 read/admin CLI는 P5a2에서 열렸다. mutating CLI/attach TTY/SSH는 후속이다. |
| detached daemon startup readiness | 구현 | fresh host launcher는 exec 성패용 CLOEXEC pipe와 daemon 준비용 inherited socket을 분리한다. daemon은 owner lease·socket bind·ready manifest·poll owner가 모두 준비된 뒤에만 `ready`, 그 전 실패는 `failed`를 보내며 launcher는 connect retry 전에 `launch_failed`를 반환한다. strict env fd parse·socket/flag 검증, ready/fail/EOF/unknown byte, 구 binary bounded timeout fallback, 실제 제품 daemon의 unsafe owner-dir 실패와 ready host 연결을 검증한다. | fresh spawn 전용이다. same-PID upgrade/restore는 기존 handoff fd layout을 사용하며 이 채널을 소비하지 않는다. 구 binary가 env를 모르면 timeout 뒤 종전 connect-backoff로 호환한다. |
| P5a1b one-shot admin policy | 구현 | `test-session-host`가 hidden `admin` hello의 owner-wide exact-one lease와 `admin_one_shot_v1`, 두 번째 admin의 `resource_exhausted` full reply+close, canonical deinit 뒤 재획득, byte-drip으로 연장되지 않는 5초 absolute request deadline과 post-hello frame 뒤 slow flush, canonical `RequestMethod` 전체의 exhaustive policy·4개 read dispatcher, privileged/non-request `unauthorized`, malformed/unknown `invalid_request`, pipelined 두 번째 request 미실행, EOF/full-close exact release, half-close reply drain과 같은 pool의 GUI 생존을 server/connection-turn/real poll-owner fixture로 검증한다. | `client_kind`는 same-UID gate 뒤의 quota hint이며 인증 identity가 아니다. hard-reserved 33번째 fd는 없고 32개가 이미 찼으면 admin도 전역 cap을 따른다. public read CLI는 P5a2에서 열렸고 mutating CLI/attach TTY/SSH는 후속이다. |
| P5a1c upgrade all-or-none preflight | 구현 | Debug/ReleaseFast `test-session-host`가 fail-closed preflight와 live capability revoke, requester exact-one dispatch, sibling partial parser/queued reply·pipelined requester 거부, 실제 prepare reservation 전에 kernel receive queue에 도착한 요청의 `MSG_PEEK` 거부·보존, 실제 runtime attachment 거부, stage busy의 reservation cancel, accepted reply 동안 sibling fd/cadence freeze와 rollback 뒤 cursor 재개, requester write failure 및 post-stage control admission 실패의 exact stage cancel+gate reopen+sibling input 보존, completed replay의 immutable path/build/hash/reader min/max exact match와 필드별 conflict preflight 우회, ReleaseFast에서도 유효한 final reactor/global authority 0 검사, full flush 뒤 canonical all-client teardown, empty-reactor aggregate counter만 남은 경우의 typed repair→`resumed/handoff_failed`→gate reopen, subscription/attachment/admin/active authority 잔여 fail-stop을 검증한다. | reservation 뒤 도착한 frame은 성공 시 close/retry 대상이며 peer quiesce fence/ACK는 제공하지 않는다. 실제 PTY 최대치 graph의 장시간 upgrade race/soak와 signed frozen N-1 제품 migration은 별도 U5/release gate다. public CLI/TTY/SSH는 P5a2 이후다. |
| P5a2 read/admin CLI | 구현 | `src/cli/runtime.zig`의 parser/help/canonical ID, 공용 `ErrorCode` 전수 exit mapping, mutually-exclusive envelope, host authority 전 필드/runtime ID, duplicate와 실제 4,097-entry decode 거부, host/get/empty/list text·JSON exact snapshot을 검증한다. socketpair는 `admin_one_shot_v1` 부재 시 request 0+close를 검증한다. 실제 제품 CLI process fixture는 secure registry의 current host 0/1/2개, 빈 registry 무생성+exit 3, invalid registry mode+exit 4, 2-current ambiguity+exit 8, exact `host status`·`runtime list/get` JSON과 list text, second admin busy, runtime not found, stdout/stderr 분리, GUI sibling과 admin admission의 `client_count` 1→2→1, 성공 조회 전후 manifest/owner lock의 inode+content 불변과 launch lock 무생성을 검증한다. Debug/ReleaseFast `test-session-host`가 모두 같은 fixture를 실행한다. | current executable과 exact build/protocol/screen/ready manifest 하나만 조회한다. N-1/특정 old host/all-host 합산과 public attach/TTY/SSH는 후속이다. capability/incompatible와 malformed response는 socket/pure boundary에서 fail-closed를 검증하며 test-only wire endpoint를 제품에 추가하지 않는다. |
| P5a3 mutating admin CLI | 구현 | unit/parser snapshot은 canonical ID·`--yes`·ASCII 공백/대소문자 confirmation과 exact success 출력, non-TTY pre-discovery exit 2와 capability 오류→exit 5 mapping을 검증한다. socketpair는 `admin_runtime_end_v1` 부재 시 close+request 0, server/connection-turn은 exact membership·admin reply 선할당 OOM mutation 0·owner queue admission 뒤 exact-once mutation·full flush close 및 GUI reply OOM에서도 기존 best-effort 종료 보존을 검증한다. 실제 제품 CLI/PTY fixture는 non-TTY `--yes` 누락 exit 2, `--yes` 성공+sibling 보존, controller/observer 연결 runtime의 prompt 전체 문자열과 종료, 거부 및 newline 없는 `yes` 뒤 EOF의 exit 9/mutation 0, 같은 host의 preview→runtime 소멸 exit 7, preview host A→current host B 교체 시 host ID pin·exit 3과 B runtime 보존을 검증한다. 모든 CLI subprocess/prompt/output/reap은 monotonic 10초 deadline과 단일 mutable process owner로 유계다. Debug/ReleaseFast `test-session-host`가 같은 gate를 실행한다. | same-UID hard gate 안의 별도 admin capability이며 CLI confirmation은 오조작 방지 UX이지 별도 인증 identity가 아니다. `runtime end`만 공개한다. `--json`, bulk/all-host end, public attach/TTY renderer/SSH workload는 후속이다. capability 부재의 public mapping은 client/socket과 local CLI seam으로 검증하며 test-only wire endpoint를 제품에 추가하지 않는다. |
| P5b1 multi-fd subscription identity | 구현 | 실제 `SocketServer`/`poll_owner.Owner`의 두 GUI fd가 같은 runtime에 observer attach해 둘 다 local stream 1과 initial snapshot `end_stream`을 받되 distinct global `SubscriptionId`/stable `ConnectionKey`로 resolve되는지, 한 fd EOF 뒤 그 subscription/attachment만 revoke되고 sibling record/socket이 유지되는지, slot 재사용 fd가 fresh key/subscription을 받고 old key는 stale인지 product poll fixture로 검증한다. 최종 두 fd close 뒤 active client/attachment/subscription 0도 확인하며, 기존 T0b0 unit의 256/8,192 cap·ABA·overflow/OOM gate를 함께 회귀한다. | public attach/TTY, retained base 회계와 slow observer backpressure, controller takeover/revocation fan-out은 각각 P5b2/P5b3 이후다. |
| P5b2a retained/prepared base budget | 구현 | 제품 poll-owner의 screen/metadata retained base와 prepared replacement를 outbound queue와 동일한 reactor `GlobalBudget`/stable tracker에 귀속한다. initial attach·periodic output·observation barrier는 projector 전 screen 16 MiB+metadata 256 KiB를 예약하고 queue admission 뒤 실제 retained 길이만 commit한다. connection steady generation 2개+prepared 1개 cap과 daemon-global prepared generation 1개 headroom을 보존한다. transaction exact cap/cap+1, old+new 동시 charge, actual reconcile, commit/rollback, prepared reclaim 중 screen/control queue admission, initial attach preflight→producer 0과 control/snapshot admission 실패, oversized `new_base`, resync projector 실패 rollback, product observation barrier, invalidation old-base release, retained EOF, 실제 slot 재사용 ABA, sibling 격리와 upgrade prepared/reclaim 0 authority를 Debug/ReleaseFast `test-session-host`로 검증한다. | projector의 `send`/encoded frame transient allocation은 이 retained/queue ledger와 별도인 기존 bounded producer peak이며 실제 RSS/slow observer가 controller·PTY·sibling cadence를 막지 않는 product artifact는 P5b2b다. P5b2a만으로 P5b 전체나 public attach를 완료 처리하지 않는다. |
| P5b2b1 product poll slow-observer isolation | 구현 | 서로 다른 controller/healthy observer/10개 slow fd의 실제 owner poll에서 non-writable queue stall을 기록하고, test-injected zero-prefix ledger pressure 중 가장 큰 stable tracker 하나만 invalidate한 뒤 healthy batch를 한 번 재시도한다. zero-prefix controller output도 lease를 유지한 채 reclaim할 수 있고 partial-prefix controller 또는 mixed controller/observer connection은 제외한다. 별도 실제 socket fixture는 유효 MRSH delta frame의 kernel short write와 후속 non-writable poll을 관측한 observer만 connection-close하고, peer의 exact incomplete prefix 뒤 EOF·완성 frame/notice 0, stale admission, controller input과 healthy observer의 두 cadence를 검증한다. base reservation 부족 fixture는 요청량보다 작은 eligible victim 하나만 실제 회수한 뒤 재예약도 실패할 때 projector 0, requester valid/base/queue와 prepared 0, exact 1초 boundary 재시도를 검증한다. batch 부족 fixture는 base feasibility와 encoded batch 실패를 ledger 부등식으로 분리하고 projector 진입 시 prepared authority와 reclaim 0/1을 probe한다. victim 1회 뒤 재admission 실패에서 atomic prefix 0, semantic base/observation cadence/queue rollback, exact boundary의 두 번째 victim 뒤 실제 wire 7-chunk·7 MiB 전체 admission을 검증한다. 일반 output batch atomic preflight, base+queue 공통 turn당 1회 reclaim, mutation-time global/slot high-water, clients/producer/subscription/attachment/budget final 0을 fixture로 검증한다. 별도 10-controller product fixture는 eligible victim 0에서 requester state/base 보존, reclaim/projector 0, 정확한 1초 backoff 재시도를 검증한다. offset-zero purge deadline 초기화와 partial-prefix purge 거부는 slot 회귀로 고정한다. 제품 ACK fixture는 유효 ACK를 owner dispatch 시각에 한 번만 수락하고 같은 invalidation epoch의 중복 ACK가 deadline을 연장하지 않는지, ACK 뒤 정확한 1초 이전 projector 0과 경계의 2 MiB+17 byte snapshot 3-chunk atomic recovery, prepared base 16.25 MiB+encoded batch 17 MiB 결합 headroom 부족 시 projector 0, metadata 성공+snapshot 실패 뒤 prefix/revision rollback·notice/ACK 재발행 없이 `resync_pending`을 유지한 정확한 1초 재시도, 실제 peer wire의 metadata 1+snapshot 3 frame 순서·마지막 chunk만 `end_stream`, 마지막 byte 전 `.resync_draining`과 이후 `.valid`, 최종 global ledger 0을 함께 검증한다. | takeover rollback 보존은 P5b3 범위다. ACK wire의 epoch nonce와 cross-epoch replay 방지는 현재 MRSH v2 계약 밖의 차기 wire 백로그이며, socketpair 제품 adapter fixture는 실제 PTY drain이나 독립 host PID RSS를 증명하지 않고 그 gate는 P5b2b2다. |
| P5b2b2 real PTY/RSS slow-observer + P4 E3a screen-idle artifact | 구현 | `zig build test-session-host-slow-observer-macos`가 driver와 별도 fixture host를 모두 ReleaseFast로 빌드한다. fixture host는 제품 `RuntimeManager`·`SocketServer`·`poll_owner.Owner`와 wire `runtime.spawn`의 실제 forkpty child를 사용한다. 기본 runtime에는 controller·읽기를 멈춘 observer·healthy observer 세 connection을 붙이고, scale phase는 실제 `/bin/cat` runtime을 1·10·100개로 늘려 각 runtime에 controller+observer를 붙인다. 각 1초 steady 창에서 `proc_pid_rusage:RUSAGE_INFO_V4` CPU와 screen snapshot/delta call·owned allocation·core-lock 증분 exact 0을 기록하고 100ms CPU cap을 판정한다. 추가 99 runtime을 종료한 뒤 기존 marker wake와 512×256 slow-observer pressure/RSS를 계속한다. private inherited DGRAM report v3은 host 진입 직후 CLOEXEC이며 child가 fd 3·4 부재를 증명한다. validator는 exact 1/10/100 행, raw latency/CPU/RSS 재계산, ledger cap/final zero, waitpid·client EBADF·socket ENOENT·directory cleanup을 fail-closed 판정한다. CI `session host slow observer macOS` job이 매 PR 실행하고 artifact를 `if-no-files-found:error`로 업로드한다. | E3a screen gate이며 E3b metadata producer visit 제거는 별도 E3b gate에서 구현됐고, P5b3 controller takeover, 외부 raw TTY·SIGWINCH·public attach·SSH packaging은 별도 범위다. allocator가 RSS를 즉시 OS에 반환하거나 post-drain RSS가 pressure peak보다 작다고 가정하지 않고, logical 회수는 final ledger 0으로 별도 판정한다. |
| P4 E3c GUI client idle-pump evidence | 제품·actual AppKit E2E·CI 연결 구현 | ReleaseFast 별도 client process가 실제 독립 host와 generation-backed `RemoteTermBackend`의 `/bin/cat` runtime 1·10·15·100개를 사용한다. 첫 실측은 15 runtime pump/seal 900·registry/socket-read 0·client CPU 4.926ms/1.576s였다. 각 idle 행은 client CPU 25ms 이하와 registry/socket-read exact 0을 hard gate로 고정한다. 강화된 60Hz·실제 fd cleanup 계측은 probe/local-input priority 뒤 100-runtime marker 2~3 frame·30.557~42.379ms로, GUI enqueue·host delivery·GUI apply를 합성한 60ms cap 안이다. actual AppKit CR6e-a2 v2의 5회 handler→Metal/probe raw 값은 15.528~24.627ms, handler 증가 exact·fd 6→6·child/daemon/socket/host artifact cleanup green이다. AppKit source는 Zig의 borrowed fd를 장기 보유하지 않고 CLOEXEC duplicate를 cancel handler까지 소유해 원본 close/fd 재사용 경합을 닫는다. runtime-scale artifact는 CI slow-observer job이 업로드 누락을 fail-close하고, required AppKit job은 attach 뒤 handshake 출력과 handler 증가·60ms를 매 PR 검증한다. | 기존 E3a/E3b artifact는 host PID와 host input acceptance 이후의 delivery 종점만 측정하므로 GUI 전체 지연 cap으로 재사용하지 않는다. 첫 실측은 4,096 registry scan 원인설과 10Hz 하향안을 기각했다. AppKit 값은 host 출력 시작 시각을 포함하지 않는 하위 구간이므로 전체 end-to-end 값으로 주장하지 않는다. |
| P5b3 controller/observer reactor | 구현 | registry prepare는 old/new exact global `SubscriptionId`와 controller generation을 고정하되 권위를 바꾸지 않고, owner가 stable `ConnectionKey`로 old client를 resolve해 `controller.revoked`와 requester response를 최대 2-frame control batch로 cross-slot all-or-none admission한 뒤 같은 AdmissionGate lease·dispatch turn에서 무할당 commit한다. controller acquire/takeover/release가 generation을 증가시키고 unpublished controller attach 실패는 generation까지 원복한다. `expected_controller_generation` CAS와 `controller.status` refresh가 제3 observer의 stale intent를 막는다. pure tests는 prepare 무변경, stale token이 replacement controller를 못 바꿈, release 뒤 observer 유지/no-auto-promotion, generation overflow·OOM을 검증한다. slot tests는 서로 다른 slot·같은 slot FIFO, stale admission, per-slot chunk/byte와 prepared-reclaim 중 shared/global hard cap의 exact/cap+1 원자 rollback을 검증한다. 실제 `SocketServer`/`poll_owner.Owner` fixture는 세 fd의 같은 local stream 1, observer takeover 뒤 old input 거부/new input 허용, 제3 observer stale reject/status refresh, poll 전 requester EOF의 두 허용 linearization, commit 뒤 requester EOF, revocation 1-byte 실제 write 뒤 old HUP와 canonical cleanup, stale prepared target의 slot ABA, takeover/release와 upgrade prepare의 양방향 kernel-queue 경합을 검증한다. takeover·release action build는 각각 fail-index 0부터 최초 무실패 index까지(상한 48) 전 allocation 지점의 commit 0과 ownership 회수를, batch 실패는 typed error만 enqueue해 requester observer/siblings 보존을 검증한다. 미지/legacy attach mode는 mutation 없이 `invalid_request`, observer `runtime.find(scroll=true)`와 exact-stream notification consume은 `unauthorized`다. notification은 stream-auth capability, legacy controller-only adapter, response admission 뒤 generation-CAS consume, max generation no-wrap와 admission 실패 no-commit을 검증한다. Debug/ReleaseFast `test-session-host`, real PTY/RSS slow-observer artifact와 전체 `mise run test`/`mise run check`를 재실행한다. | public 제품 client의 `controller.revoked` role cache/전환과 `maru attach`/raw TTY/`SIGWINCH`/resize broadcast/SSH는 P5c/P5d 범위다. action-build allocator 완전 고갈은 prepared authority를 원복한 뒤 requester connection을 canonical fail-close하며, batch admission 실패는 prebuilt typed 오류로 connection을 보존한다. controller transition은 owner turn 밖에 pending 상태를 남기지 않고 queued control과 attachment가 기존 upgrade drain을 막는다. |
| P5c1 external raw TTY lifetime | 구현 | pure injected-ops fail-index가 termios/window-size/signal-mask/signal-pipe/handler/raw-enter 각 실패의 mutation 0 또는 retryable exact rollback과 idempotent restore를 검증한다. setup/restore transaction은 종료 signal을 block하고 원래 mask를 복원해 handler/raw/pipe 경계 race를 닫는다. process-unique owner token은 stale struct copy의 반복 cleanup을 거부한다. macOS in-process `openpty` fixture는 non-default size와 libc `cfmakeraw(3)` 전환·정상 exact restore, pipe `O_NONBLOCK|FD_CLOEXEC`와 restore 후 `EBADF`를 검증한다. 별도 5초-deadline child fixture는 `HUP/INT/QUIT/TERM` 각각의 byte-for-byte termios 복원과 default signal exit status를 검증한다. invalid pipe byte typed reject, `SIG_IGN`/custom disposition mutation 전 reject, fork child PID mismatch가 parent pipe를 깨우지 않음도 고정한다. pure ExitReason 전수는 detach·EOF·protocol/socket 오류가 같은 restore를 사용하고 runtime terminate request가 0임을 고정한다. Debug/ReleaseFast `test-session-host`와 전체 회귀를 재실행한다. | 공개 `maru attach`의 실제 detach/EOF/socket E2E와 single-thread/no-fork integration, renderer/input forwarding, detach chord는 P5c3, SSH packaging은 P5d 후속이다. `SIGKILL`/host crash는 cleanup 코드를 실행할 수 없어 복원을 보장하지 않는다. |
| P5c2 external resize and broadcast | 구현 | pure `ExternalResizeState`가 unchanged/zero suppression, observer request 0, controller attach/takeover forced first request와 실패 무변경, revoke 뒤 새 request 0, JSON `i64` counter exact/max와 host generation duplicate/older ignore·gap 적용을 검증한다. 실제 `openpty` child는 `TIOCSWINSZ`+`SIGWINCH` burst의 latest size candidate coalesce를, 별도 포화 fixture는 WINCH로 self-pipe가 가득 차도 atomic pending class의 TERM 우선·resize 0을 검증한다. registry prepared token은 stable runtime ID·controller generation·current-ledger delta로 stale/double commit·controller 왕복 ABA·sibling interleave·handoff generation max+1을 typed reject한다. mixed publication은 slot별 256-bit tracker set으로 최대 subscription 검사를 선형화하고 monotonic reservation ID를 backend 전 확보해 cancel→새 reserve 뒤 old-token ABA를 거부하며, 실패 시 취소·성공 시 무실패 consume한다. 실제 `SocketServer`/`poll_owner.Owner` fixture는 controller response+broadcast, invalid observer connection fail-close 뒤 target rebuild, backend 실패 reservation 취소, records/items/per-event allocation fail-index 전수와 injected owner admission 실패의 backend·size·sequence·generation mutation 0을 검증한다. 별도 reactor cap+1 rollback과 한 observer connection의 복수 stream 누적 local cap을 고정한다. client는 metadata/resize를 별도 bounded full-state로 보존하며 같은 stream의 foreign runtime resize는 coalesce와 즉시 소비 양쪽에서 connection protocol fail-close한다. strict decoder/parser가 exact runtime ID/size/generation/reason, echoed sequence/applied size/generation/changed와 malformed/foreign/stale/gap 적용을 검증한다. Debug/ReleaseFast `zig build test-session-host`를 통과한다. | 공개 `maru attach` event loop/input renderer/detach chord와 이미 adapter가 소유한 pending request 취소는 P5c3, SSH packaging은 P5d 후속이다. 기존 GUI remote runtime은 broadcast를 적용하지만 외부 raw TTY adapter를 실제 CLI에 묶는 것은 P5c3 범위다. |
| P5c3 public attach CLI | 구현(P5c3a~d 완료) | P5c3a는 pure/product resolver, closed `Client.ConnectionProfile`, `RemoteAttachment` role/screen SSOT와 revoke fence를 고정한다. P5c3b는 `ScreenSource` lock 안의 neutral `RenderSnapshot`을 `external_ansi`가 immutable full repaint로 만들며 cursor 선행 hide, ED2, anchor별 CUP, 허용 SGR, C0/C1/DEL 치환(우하단 위험 anchor는 전체 grapheme ASCII `?` 대체), crop/wide/grapheme/cursor를 검증한다. malformed DTO·cropped/continuation까지의 invalid Unicode/unsupported style·grapheme entry/aggregate cap+1·우하단 caller-width-independent ASCII placeholder·viewport cell cap·실제 32 MiB two-pass exact-storage cap/cap+1·allocation fail-index, queue-owned builder 구조의 current/latest 64 MiB 상한과 stale projection sequence 사전 거부를 Debug/ReleaseFast로 고정한다. P5c3c-1a는 explicit wire major의 `Client.connectUntil`이 기존 parser/`finishHello` SSOT를 재사용하고 injected connector ops, exact absolute deadline, `EINPROGRESS→poll→SO_ERROR`, CLOEXEC/SO_NOSIGPIPE, real socketpair partial I/O·peer-close, malformed/partial EOF close, 전체 hello allocation fail-index와 실제 host hello 후 blocking 복원을 고정한다. 1b는 네 독립 phase의 absolute deadline을 resolver/revalidation/retry/connect/hello/call/snapshot/status/takeover와 semantic publish까지 전파하고, deadline-first filesystem/connect/I/O 실패, fd flag lease 복원, canonical poison/close, retry 만료 뒤 작업 0, coalesced snapshot/revoke 선소비, allocation fail-index와 실제 제품 host transaction을 고정한다. 2a는 같은 `Client`의 단일 blocking/external mode, 64-frame descriptor 사전 할당, exact fd-flag 검증·rollback/fail-close, parser/inbox/request/capability 보존, legacy API 전수 wire-0 reject와 external storage exact-once cleanup을 injected ops·allocation fail-index·실제 Darwin socketpair·제품 attach fixture로 고정한다. 2b1은 tagged batch lease와 stable 18 MiB/4,096-item ledger를 GUI `RemoteAttachment`의 실제 consumer에 적용해 exact cap, out-of-order slot reuse, generation exhaustion, stale-copy/double-release, failed-release terminal retain/retry, append/apply/deinit release-before-drop cleanup과 sibling stream fail-close를 Debug/ReleaseFast 및 전체 check로 검증한다. 2b2는 열네 merge gate이며 2b2a~c2, 2b2c3-c3a1~a2, 2b2d1, 2b2d2a와 2b2d2b의 d2a~d 및 2b2e-core와 2b2f1~f2까지 구현했다: 2b2a pure closed state/DTO·parser exact normalize·source boundary, 2b2b final-address `ExternalPumpStorage` scaffold, 2b2c1 phase-aware ledger transaction, 2b2c2 prepared Client inventory/authority/request adoption, 2b2c3은 내부 gate c3a1(common wire+product decode+CLI raw FIFO)→c3a2(prepared normalize+paired transfer)→c3b(single-inventory staging/FIFO reducer)→c3c(typed token take/combined final commit)로 나눠 네 gate 전체를 완료 조건으로 삼는다. 2b2d1은 O(1) absolute-offset RX provenance/parser를 완료했고, 2b2d2a는 sealed frame-range pure classifier를 완료했다. 2b2d2b의 d2a~d는 RX-first whole-turn authority barrier와 actual socketpair/product hostile gate까지 완료했다. 2b2e-core는 origin-tagged `RecoveryKey`·closed reducer·`RemoteAttachment`의 borrow→preflight→shadow apply→release→mark→visible publish와 `ExternalPumpStorage.pumpRxTurn`의 fresh-clock commit→same-turn RX를 고정한다. 잘못된 incarnation/origin/epoch/token generation은 visible screen을 바꾸지 않고, mark 뒤 stale 판정도 shadow를 폐기하며 lease를 다시 잡지 않는다. `applied_pending`만 immediate-turn latch이고 deadline-1/exact/+1을 같은 API로 판정한다. TX offset/fully-sent와 response correlation이 아직 없으므로 recovery 충돌표 전체와 2b2e 완료 표시는 2b2e-integration이 소유한다. 2b2f1 TX/request-ID와 2b2f2 control correlation/response ownership, 2b2f3-f3a pure planner와 f3b sealed cancellation/cleanup handoff까지 구현 완료다. f3c0 substrate와 pre-token authority/barrier recovery contract correction, f3c1-base·f3c1-terminal-binding·f3c2~e와 2b2e-integration, 2b3, 3a1~3b 및 P5c3d까지 완료했다. 열네 gate가 모두 green이기 전에는 2b2 완료가 아니다. 2b3은 이 scaffold가 실제 `external_attach.Prepared`의 already-decoded evidence를 재파싱 없이 consume하는 non-movable product adapter와 attachment→Client→ledger final-zero teardown만 소유하며 normalize/adoption을 복제하지 않는다. P5c3c-3a는 dedicated tty output/chord/deadline/pre-raw commit barrier를, 3b는 RawTty/ANSI·resize·signal integrated owner와 partial-wire cleanup을 고정한다. P5c3d는 built product+실제 host/runtime+`openpty`의 controller/observer/takeover/detach/reattach와 별도 ANSI state oracle을 구동한다. P5c3a~d의 모든 slice가 병합되어 P5c3을 완료로 표시한다. | 2b2a~f3는 timer-only 5/10/30초, parser header 1/31/32·payload-1 freshness, same-read response 뒤 snapshot 허용·pre-response partial 거부·pre-ACK buffered snapshot 거부와 1-byte drip O(1) metadata, 4,096 zero-byte entry의 payload/checked dynamic-metadata 독립 cap·final-zero를 고정한다. c3a1은 common wire 5종+unknown/foreign/malformed, duplicate-key and semantic digest collision injected exact fallback, exact control-cap string and 8 KiB-over escaped string, actual attach-response unsupported/unavailable/current seed, revision-max close/reattach-1, process tail equality, CLI raw FIFO와 GUI common DTO를 검증한다. c3a2는 staged parser normalize, Prepared 기반 provenance bridge, metadata descriptor-first seal, Client+seed paired take, 전체 allocation fail-index, pointer/content/profile/cross-attach drift와 post-pair cleanup, 실제 allocator callback의 direct/cross-storage init 재진입 latch·proof alloc tag/profile drift typed reject·paired take 뒤 final proof free·양 cleanup mirror poison 거부·teardown busy를 검증하고, c3b는 source 불변/allocation fail-index, zero request-ID raw seal, valid-owner descriptor/len/cap/alias ABA dereference-before-reject and cleanup-mirror exact once, FIFO reducer, initial epoch 0-to-1 and deadline overflow, stale same-backing mutation을 검증한다. c3c는 prepare adopted/recovery/terminal 3-way outcome and adopted commit, sealed request/authority take, verdict별 metadata cleanup, owner-event borrow lease/failed projection retry, partial-consume teardown/ledger final-zero를 검증한다. 2b2e-core는 null recovery key의 mark 0회, exact key의 mark 1회, wrong incarnation/origin/epoch/token generation의 preflight 거부와 mark 직전 stale 전환, same-address reincarnation, cross-storage 격리, shadow screen publish 순서, deadline-1/exact/+1 fresh-clock commit과 같은 turn buffered RX를 Debug/ReleaseFast component·boundary·전체 check로 검증한다. 이후 transfer fail-index, readable+writable revoke 1/64/65와 write 0, 2b2e-integration은 actual token binding·recovery 충돌표·cleanup fail-index를 Debug/ReleaseFast로 검증한다. f3e는 partial TX revoke와 제품 orchestration을 socketpair·stress로 자동 검증한다. P5c3d가 pre-P5b3 same-major fixture source/fingerprint를 먼저 hermetic input으로 추가해 resolver old-host 선택, observer attach 성공, takeover request 0, 1 match+1 inconclusive와 one-sided/different TTY attach/discovery 0, pre-raw byte-drip/read/write stall deadline 연장·raw mutation 0, inherited fd flags 전후 불변, stdout/socket stall·partial repaint/wire 중 signal/revoke bounded cleanup, 생존 assertion 뒤 explicit fixture terminate와 ledger 0을 고정한다. 실제 Terminal.app/iTerm2/Ghostty 자동화는 비차단 compatibility smoke이며 localhost SSH는 P5d다. |
| P5d SSH packaging/smoke | 부분 구현(bundle/PATH·localhost sshd 제품 PTY 구현, provisioned Developer ID 실행 대기) | `macos-app-bundle`의 regular executable CLI와 strict ad-hoc signature, 격리 HOME `install-cli`, 최소 원격 PATH의 public `attach` help 및 fake-PATH 음성 행을 검증한다. harness 소유 임시 key·고포트 `/usr/sbin/sshd`와 독립 `openpty`의 `/usr/bin/ssh -tt`가 제품 daemon runtime에 `env PATH=<isolated-bin> maru attach <runtime-id>`로 접속해 marker/input exact-once, detach 뒤 runtime 생존, 재attach, observer 입력·resize 0과 takeover CAS/revoke를 검증한다. `tools/session-host/p5d_ssh_smoke.sh`와 required CI `session host bundled CLI macOS`가 ad-hoc 경로를 Debug 전수 스위트와 병렬로 자동 실행한다. provisioned release runner는 추출 artifact의 GUI·CLI·helper 동일 TeamIdentifier, hardened runtime, universal slice를 확인한 뒤 같은 SSH smoke를 재실행한다. | 사용자 SSH 상태와 Remote Login 설정을 읽거나 수정하지 않는다. sshd prerequisite 부재나 Developer ID 미제공을 skip/pass로 세지 않으며 각각 미완료와 `not_provisioned`로 기록한다. ad-hoc gate는 `not_provisioned`를 출력하고 Developer ID 요구 모드에서 fail-close한다. 세 gate가 모두 green이기 전에는 P5d 또는 signed 배포 호환을 완료로 표시하지 않는다. |
| S11-6 뷰포트 선언(폰이 자기 격자를 알린다) | 구현(3a·3b «주고받기» + 3c «적용»·«말하기» 완료) | 3a·3b 를 `test-macos-only` 가 PR 에서 돈다: `maru-attach-stream-consumer` (13개, `--maru-expect-tests` 로 개수 고정)가 `MRSV` 프레이밍·폭풍 접기·밀린 값 재시도·닫힌 채널을, `registry`(5개)가 슬롯 수명·거둠/버림/무변화·controller 인수인계를, `server`(2개)가 실 프레임 왕복과 **`runtime.get` 모양 불변**을, `client_control_correlation`·`client_pump`·`client_external_pump`(3개)가 「observer 가 controller generation 0 으로도 낼 수 있는가」와 「옛 host 의 거절이 terminal 이 아닌가」를 지킨다. `cli.runtime`(3개)이 `runtime get` 텍스트·`--json` 출력을 문자열로 못박는다. 3c 는 `socket_server`(6개)가 tick 이 선언을 실제 크기로 옮기고 폰이 떠나면 되돌리는 것·폭풍에도 리사이즈 한 번·PTY 실패 시 registry 불변·세션 간 격리를, `poll_owner`(1개)가 조정 알림이 **client 의 strict decoder 를 통과하는지**(`data.count == 5`·`reason:"controller"`)를, `remote_runtime`(3개)이 「남이 좁혔나」를 요청값과 확정값만으로 정하고 그 상태가 **연결보다 오래 사는지**를, `app_session`(1개, `SB1-S11-6`)이 그 값이 상태줄 항목으로 **실제 조립되는지**를 지킨다. **주입 없는 판정자 둘을 뒤에 더했다**(2026-09-03): `remote_runtime` 이 실제 `runtime.resized` wire 를 태워 붙을 때·떠날 때·**내가 줄일 때**를 가르고, `app_session` 이 `test_narrowed_cols_override` 를 쓰지 않고 진짜 runtime 을 앱 전역 backend 에 심어 조회 몸통(로컬 Term·handle 불일치·0)과 조립된 셀의 아이콘·숫자까지 본다. 자리는 경계 게이트 `tests/session_host_s11_6_narrowed_boundary.zig` 가 센다 — 확정 이벤트를 적용하는 두 자리가 모두 판정을 부르는지, 초기화 두 자리가 상태를 0 으로 쓰는지, 그리고 판정이 리사이즈 **응답** 경로로 새지 않았는지(앵커로 못 박는다). **전달 자체를 재는 자리도 생겼다**(2026-09-03): `client_external_pump` 가 실 socketpair 에서 「관측자가 admit 한 `declare_viewport` 가 **조용한 턴**(읽기가 언제나 `would_block`)에도 소켓 **반대편에 도착**하는가」를 바이트로 본다. 클라와 host 를 각각 단위로 재는 판정자는 그 사이 전달을 원리상 못 봐서, 이 축이 제품에서 통째로 안 도는 것을 아무도 못 잡고 있었다. 같은 경계 게이트가 `--stream` 루프의 TX 계약 둘(실었으면 쓰기 관심·쓰기 턴에 RX 프리픽스)과 `detach` 하드코딩 0건도 센다. 폰 쪽 송신은 `mobile_bridge_contract`(3개)가 같은 값 재전송 안 함·못 보낸 선언 재시도·채널이 바뀌면 버림을 못박는다. 실 데몬에 실제로 붙어 선언이 통하는지는 `external_pump_owner` 의 판정자가 보되 **`test-session-host` 에서만** 돈다(그 잡은 2026-08-31 결정으로 PR 에서 안 돈다) — 그래서 같은 계약을 값싼 순수 판정자로 PR 게이트에 한 번 더 걸어 두었다. | **그 주입 없는 판정자가 첫 실행에서 결함 둘을 찾았다**(2026-09-03) — ⑴ `spawn`·`attachExisting` 이 이 상태를 초기화하지 않아 상태줄에 「폰 43690열」(0xAAAA)이 뜰 수 있었고, ⑵ 판정이 legacy 이벤트 갈래에만 있어 **제품이 쓰는 generation 경로에서 알림이 통째로 무동작**이었다. 즉 이 행이 「구현」이던 동안 사용자에게 보이는 절반은 안 돌고 있었다. **실기로 「폰을 붙였더니 맥 세션이 좁아지더라」를 2026-09-03 에 처음 봤다**(PR#3149). 임시 격리 HOME + 실 데몬 + 실 `maru attach --stream` 으로 `95x27` → `50x27`(`runtime get` 에 `declared stream=2 50x20`) → 관측자가 떠나자 `95x27` 복귀를 확인했고 스트림 CPU 는 0.0% 였다. **그 회차가 이 축이 제품에서 통째로 안 돌고 있었음을 드러냈다** — 폰이 보낸 선언이 host 에 한 번도 도착하지 않았다(관측자 control 의 TX 자격이 `detach` 전용이었고, `--stream` 루프가 TX 계약을 안 지켜 조용한 세션에서는 쓰기 턴 자체가 안 왔다). **절차의 함정 둘**: `MARU_SESSION_HOST_ROOT` 로 격리하면 데몬이 안 뜬다(override 를 빼면 즉시 뜬다), 그리고 앱이 host-backed runtime 을 **간헐적으로 안 만든다**(신선한 격리 HOME 으로 다시 띄우면 산다 — 원인 미확인). 실기 중 CLI 를 재빌드하면 옛 데몬과 build_id 가 갈려 `persistent session host absent` 로 보이므로 데몬·앱을 함께 재시작한다. **그래도 남는 것** — 자동 게이트는 전부 헤드리스이고, 시뮬레이터+임시 sshd 회차([S11-7](plans/ssh-client.md))는 이 축이 서기 전에 돌았다. 수동 재현은 그 회차와 같다: 임시 sshd 위 격리 HOME 앱 → 폰이 세션 화면을 열고 → `maru runtime get <id>` 의 `cols` 가 줄고 맥 상태줄에 `📱 폰 N열` 이 뜨는지 → 폰을 나가면 되돌아오는지. 상태줄 항목은 **조립까지만** 잰다 — 그 항목이 실제 픽셀로 그려지는지 보는 골든은 없다. 행은 계약상 안 바꾸므로(맥 창이 23행을 잃는다) 창 위로 넘는 행은 여전히 안 보인다. |

> **keep-alive 경로 CI 게이트(2026-08-28):** `session-host-keepalive-macos` 가
> `macos-session-host-recovery-smoke` 와 `macos-session-host-r1-tombstone-smoke`를 PR·푸시에서 돌린다.
> 전자는 **keep-alive 를 실제로 켜고 도는 유일한 CI
> 잡**이다. `session.keep-alive-after-quit = true` 인 홈에서 앱을 두 번 띄워 「GUI 를 껐다 켜도 **같은
> 프로세스**에 다시 붙는다」를 실 AppKit 창으로 end-to-end 단언한다: `stage=2`(두 번째 실행) ·
> `row_present`(살아남은 세션을 목록에서 찾음) · `click_dispatched` · `remote_published`(원격 터미널이 섬) ·
> **`marker_present`(1 차 셸의 표식이 2 차에서 보임)** · `before/after_capture`(렌더 캡처).
> **오래 「CI 에서 못 돈다」고 적혀 있었으나 시도한 적이 없는 가정이었다** — 재 보니 러너에 WindowServer 가
> 있고 통과한다(2분 14초, macOS 잡 중 최저). 후자는 ended manifest를 제품 checkpoint 생성본으로 두 번
> 재실행하고 각 실행의 직접 child 0과 `SIGKILL` 뒤 exact tombstone을 확인한다. ⚠️ 덮지 않는 것: live runtime이
> 있는 최신 멀티 윈도우 checkpoint의 강제 종료 복원(R7), GUI 부재 중 알림(OS 배너), Developer ID artifact.

> **host launch 실패 즉시 감지(P3-d2d, 2026-08-25):** double-fork 는 손자를 orphan 으로 만들어 부모에게
> `waitpid` 할 자식이 없다. 그래서 `execv` 실패를 **알 방법이 아예 없었고**, 호출부가 재시도 예산
> (150 × 20ms)을 통째로 문 뒤 `startup_timeout` 으로 끝냈다 — **실측 4123 ms**(파일은 있는데 실행이 안 되는
> 상태 = 부분 설치·격리된 바이너리). 이제 부모가 파이프 쓰기 끝에 `FD_CLOEXEC` 를 걸어 손자에게 넘긴다:
> exec 성공이면 커널이 닫아 **EOF**, 실패면 손자가 **`errno`** 를 적고 죽는다. **재측정 5 ms**, 사유도
> `startup_timeout` 이 아니라 `launch_failed` 로 정확해졌다(콜드런치 자체는 불변 — 중앙값 110 ms).
> 자동 gate 는 `zig build test-session-host` 의 launcher 판정자 둘(실행 권한 없는 파일·없는 경로)이며
> **시간으로 단언하지 않는다**(느린 CI 에서 흔들린다) — 옛 동작에는 오류 자체가 없었으므로 「오류가
> 돌아오는가」로 회귀를 잡고, 기존 marker smoke 가 성공 경로를 지킨다. ⚠️ exec **뒤** `ManifestFailed`·
> `OwnerLeaseFailed` 로 죽는 경우는 CLOEXEC 로 fd 가 이미 닫혀 여전히 예산을 다 문다(후속 — daemon 이
> CLOEXEC 아닌 fd 를 물고 bind 때 닫아야 하고, fd 번호는 strict argv 파서 때문에 **env** 로 넘겨야 한다).

> **P5c3c-3a1 완료 증거:** `test-session-host-3a1`이 P5c3c-2b3을 상속하고 detach chord,
> stdout progress/deadline, final-address `DedicatedOutput`을 Debug·ReleaseFast 각 3개와
> boundary 1개·test-name sentinel로 고정한다. 실제 `openpty`는 전용 output이 별도
> open-file-description이며 `O_NONBLOCK|FD_CLOEXEC`이고 inherited stdout status flags는
> init/deinit 전후 byte-for-byte 불변이며 전용 fd만 닫힘을 증명한다. injected failure matrix는
> path/flags/open/세 fstat/character-device/identity drift에서 publication 0과 opened fd exact close를
> 증명한다. 이 완료 표시는 3a1 primitive에만 해당하며 3a2가 아래에서 별도 완료됐어도 3b 제품 loop와
> P5c3d E2E는 미완료다.

> **P5c3c-3a2 완료 증거:** `test-session-host-3a2`가 3a1과 P5c3c-2b3을 상속하고
> prepared TTY inspection, final-address `PreRawOwner`, dormant-product boundary를 Debug·ReleaseFast로
> 고정한다. 실제 `openpty`는 prepare 전후 termios·ANSI mutation 0, commit의 exact enter와
> stdin/socket/output/signal poll set, teardown의 exact leave, dedicated output 선-close 뒤
> `TCSAFLUSH`의 bounded return과 byte-for-byte termios restore를 증명한다.
> pre-commit window-size drift, partial enter write와 best-effort leave/output close/restore, initial repaint OOM은
> raw mutation 또는 cleanup authority 유실 없이 prepared/tearing-down/dead 상태로 수렴하고 partial enter 뒤
> 재-commit을 거부한다. repaint allocator의
> teardown 재진입과 commit 중 enter writer의 teardown 재진입은 typed busy로 거부해 active transaction과
> final owner를 보존한다. `ExternalPumpOwner`의
> retryable busy teardown도 authority를 보존한다. boundary는 `PreRawOwner` 선언과 raw commit composition을
> 한 모듈로 제한하고 3b 전 제품 caller exact 0을 증명한다. 따라서 3a는 완료지만 실제 CLI poll loop와
> 사용자 제품 동작은 3b, built app/host 재접속 E2E는 P5c3d 범위다.

> **P5c3c-2b3 완료 증거:** `ExternalPumpOwner`의 최종 주소 seal, 실제
> `external_attach.Prepared` 일회성 consume, attachment transport의 storage-only opaque borrow,
> attachment lease 반환 선행 teardown을 독립 RED→GREEN으로 고정했다. Debug/ReleaseFast 전용 gate는
> 9/9, 전체 `mise run check`는 주 통합 3,779 pass/83 skip/0 fail, 후속 단위 3,324 pass/23 skip/0 fail,
> session-host aggregate 2,299 pass/45 skip/0 fail과 전체 boundary green으로 완료했다. 이 증거는
> stable product binding만 닫으며 raw TTY loop와 실제 public CLI E2E는 3a·3b·P5c3d 범위다.
>
> 2b2f2는 outstanding control을 하나로 제한하고
> (a) pure correlation reducer,
> (b) TX/request-ID와 semantic correlation의 atomic admission 및 exact completion seal,
> (c) RX deadline/header/request-ID preflight 뒤 기존 raw response owner를 대체하는 completed owner,
> (d) completed source-turn에 결속된 private prepared take와 비탈출 exact-once
> cleanup/product socketpair 네 gate를 모두 통과해야 완료다. f2에서는 제품 semantic apply를 열지
> 않으며, f3가 same-drain revoke/EOF 우선순위와 authority-clear drain permit을 닫기 전 public
> control/whole-turn 완료를 주장하지 않는다. f2 completion evidence는 (1) `admitControl` 실제
> allocation 실패 전수와 공통 final-zero, (2) product max-ID enqueue→TX→response→private reject
> cleanup 및 f1 exhaustion leaf, (3) 실제 socket RX-first readable+writable와 두 방향 역순 response,
> (4) product deadline-1/exact/+1을 모두 포함한다. f2에는 정상 success/idle 복귀 권위가 없으므로
> max-ID 성공 take 뒤 같은 product storage의 다음 wire-zero exhaustion은 f3 typed-success integration
> gate가 검증한다. test-only correlation reset은 이 경계를 대신하지 않는다.

> 2b2f3는 recovery mutation을 소유하지 않는다. f3의 완료 범위는 reducer-sealed pre-event
> authority 기준 revoke priority, exact offset-zero TX/control cancel, partial/retired/response-wait
> protocol close, `completed_awaiting_drain`과 private whole-drain permit, typed resize success,
> transport terminal/owner cleanup이다. resync는 sealed `resync_ack` verdict까지만 만들고
> `control_in_flight → awaiting_snapshot`, host invalidated/ACK 충돌표, pre/post-ACK snapshot과
> fresh-clock recovery commit은 2b2e-integration이 단독 소유한다. f3a pure planner와 f3b sealed
> cancellation·same-lease cleanup replay·persistent-failure bounded quarantine handoff는 첫 merge slice로 완료했다.
> shared codec·`ControlExpectation`·opaque permit/verdict와 private consumer signature만 여는 f3c0 substrate를
> 둘째 slice로 병합했다. recovery contract correction으로 미래 ledger token generation을 control caller가
> 예측하지 않는 `RecoveryControlAuthority`와
> `awaiting_snapshot{barrier}→snapshot_in_flight{committed-generation candidate binding}`을 고정했고 permit producer의
> 순환도 제거했다. f3c1-base는 single-turn permit/typed verdict의 private producer를, f3c1-terminal-binding은
> non-owning terminal evidence의 기존 cleanup destination 결속과 private exact cleanup을 완료했다.
> 2b2e-integration도 private same-lease resync ACK/snapshot transaction과 actual-ledger-token binding을 완료했다.
> f3c2 semantic take와 f3d 기존 whole-turn 제품 orchestration에 이어 f3e hostile evidence도
> pure 1개+제품 5개 exact-count gate로 완료했다. pure 닫힌 곱, injected whole-turn, 실제 Darwin socketpair,
> allocation fail-index/bounded stress의 네 층은 서로 대체하지 않으며 common
> TX/parser/ledger/completed/FD final-zero를 검증한다. 다음은 stable product binding인 2b3이다.
> resize/resync payload schema는 dependency-neutral `control_response_wire.zig`
> codec 하나를 기존 `RemoteRuntime`과 external pump가 공유한다. response/revoke/EOF 양순서,
> revoke 1/64/65와 parser resident 65, readable+writable write 0, input/control offset 0/partial/
> retired/response-wait, max-ID success 뒤 same-storage exhaustion, deadline-1/exact/+1과 common
> TX/parser/ledger/completed/FD final-zero가 모두 Debug/ReleaseFast·boundary·전체 check에서 green이기
> 전에는 f3나 2b2 완료로 표시하지 않는다. 실제 stable poll/close adapter와 final owner binding은 2b3다.

> Recovery contract correction gate는 Debug/ReleaseFast
> `zig build test-session-host-recovery-contract`로 pre-token control authority와 barrier/origin/epoch/range를 받는
> pure committed-generation binding plan을
> 각각 non-empty component test 및 executable sentinel에서 검증한다. `ControlExpectation.resync` 또는 control
> admission에 `expected_token_generation`이 다시 들어가거나 `preflightBatchAuthority`/`markResyncApplied`가
> barrier-only `awaiting_snapshot`을 허용하면 boundary/full session-host gate가 실패해야 한다. 이 correction만으로
> f3c1, 2b2e-integration 또는 recovery product orchestration 완료를 표시하지 않는다. actual ledger commit
> receipt/storage seal은 pre-ACK f3c1이 아니라 snapshot commit 뒤 2b2e-integration preparation이 소유한다.

> f3c1-base gate는 single-turn final-EAGAIN, post-response side-intent 0, multi-turn episode 0인 private producer만
> 증명한다. exact drain evidence address/digest binding과 source-mutation 0을 green으로 만들더라도 terminal cleanup
> binding/consumer, side-intent array와 episode advance는 각각 후속 gate의 증거가 필요하므로 f3c1 전체나 2b2e 완료로 승격하지 않는다.

> f3c1-terminal-binding은 base의 immutable prepared terminal evidence와 별도 lifecycle의 scratch final-address
> binding/take/frozen destination을 단방향 seal로 묶고, private exact
> consumer가 callback-free owner move와 reason-preserving absorbing terminal publication을 먼저 끝낸 뒤 payload를 exact
> once free한다. allocator callback drift의 `cleaned_with_invariant`는 canonical terminal snapshot을 복원하고 global
> quarantine을 latch하며 retained payload bytes 0으로 닫는다. generation max는
> wrap 없이 absorbing terminal로만 전이한다. 이 gate의 product callsite는 0이며 f3d가 나중에 exact-one branch를 소유한다.
> decode callback이 completed/correlation/parser/authority/TX를 coherent reseal하면 current owner를 다시 읽어 cleanup
> capability를 발급하지 않고 graph 0의 `not_ready`로 outer invariant teardown에 넘긴다.
> 따라서 binding component gate만 green이어도 f3c1/F3/2b2 전체 완료로 표시하지 않는다.

> 2b2e-integration은 기존 `planRecoveryTransition` 하나를 `resync_ack` trigger로 확장해 exact client
> `control_in_flight`+response-wait+nonzero barrier+deadline 미만만 `awaiting_snapshot`으로 계획한다. pump 내부의 별도 ACK
> switch/reducer는 허용하지 않는다. Snapshot binding은 commit 전 actual-token 없는 `PreparedRecoverySnapshotCommit`과 commit
> 직후 no-fail suffix가 final address에 쓰는 `CommittedRecoverySnapshotBinding`의 두 lifecycle이다. Precommit source는
> `commit_pending{prepared_live_commit}` 또는 `already_committed{immutable_commit_output}`의 closed union이며 전자만 ledger commit을
> 수행하고 후자는 same-drain side-intent의 기존 output을 쓰므로 permit 재사용/두 번째 commit이 0이다. 두 source가 actual
> commit output을 얻은 뒤 수렴하며, `CommittedRecoverySnapshotBinding`만 ledger commit이
> 발급한 actual token slot+generation과 sealed recovery intent/provenance/storage-incarnation/held-lease를 capability로 사용하며
> predicted next generation이나 pure plan DTO를 authority로 쓰지 않는다. ACK transaction과 snapshot transaction은 별도
> final-address receipt/lifecycle이며, 전자는
> `control_in_flight→awaiting_snapshot`, 후자는 actual ledger commit→`snapshot_in_flight`만 소유한다. 같은 drain에 이미 commit된
> post-response side-intent가 있을 때만 두 prepared transaction을 순서대로 consume하고, candidate가 없으면 후속 turn의 snapshot
> transaction이 독립 실행된다. 각 no-fail suffix는 semantic publication과 capability tombstone을 먼저 게시할 때까지
> allocator/callback/clock/syscall/fallible lookup 0이어야 한다. Completed payload free는 ACK canonical publication 뒤의 별도
> publish-before-free callback tail이며 snapshot consumer는 payload/allocator를 소유하지 않는다.
>
> ACK receipt one-field matrix는 self/storage/scratch/lease address, owner incarnation, lease/operation/turn/parser generation과
> parser seal, sampled clock/deadline, authority state/generation/seal, permit/verdict/completed/correlation/TX digest, barrier와 pristine
> destination을 포함한다. Precommit snapshot matrix는 source union, 최대 64개 disposition aggregate의 final address/count/root
> digest와 entry별 token source/provenance/range/disposition/cleanup destination, pristine committed-receipt destination을 포함한다.
> Committed snapshot receipt matrix는 별도 self/lifecycle, 같은 storage/lease/turn authority, current awaiting digest,
> ledger identity/authority digest, full token slot+generation, committed slot semantic digest/RecoveryIntent, origin/epoch/snapshot/range,
> side-intent address/digest, source discriminator와 destination pristine digest를 포함한다. Debug/ReleaseFast component gate는
> actual-generation/slot reuse, barrier 전·걸침·후, copy/move/cross-storage/cross-lease/replay, 위 필드별 tamper, multi-candidate
> first-exact/drop transaction과 fail-index를 검증한다. ACK callback tail은 post-publication recovery/correlation/input 및 모든
> tombstone/owner seal snapshot을 기준으로 `cleaned|cleaned_with_invariant|invalid_precommit`을 반환하고, 안전한 scalar drift만
> 복원하며 allocator pointer/ledger/storage lifecycle drift는 추가 free/release 0+bounded quarantine으로 닫는다.

> f3c2는 얇은 final-address `PreparedControlSemanticTake`의 `resize|resync` closed union으로 branch receipt의 exact
> address/digest/lifecycle만 묶고 공통 authority는 branch receipt에 단일화한다. Resize branch는 host-authoritative full-state generation/equivocation reducer와
> owner-resize pristine destination을, resync branch의 단일 `PreparedResyncSemanticCommit`은 ACK transition, projected state와
> optional same-drain recovery aggregate/output/binding을 봉인한다. Outer wrapper는 branch receipt 하나만 참조하며 independent
> ACK/receipt/aggregate splice와 optional none↔some flip을 거부한다.
> Resync aggregate는 ACK 뒤 다시 검증하는 구조가 아니라 ACK transition의 projected `awaiting_snapshot`을 사용해 semantic
> publication 전에 disposition/live-commit/binding destination을 모두 preflight한다. no-fail suffix는 response move, branch semantic,
> correlation idle, optional ledger actual-token binding과 모든 tombstone을 게시한 뒤에만 payload callback cleanup을 실행한다.
> f3c2 결과는 `consumed_resize_cleaned|consumed_resync_cleaned|cleaned_with_invariant|invalid_precommit`이고 post-publication
> ordinary failure는 없다. 모든 source/destination `{addr,len}`은 checked-add한다. 서로 다른 top-level object/external referent는
> pairwise non-alias, parent↔declared inline child는 exact compile-time offset/size, sibling은 non-overlap이어야 한다. adjacent는
> 허용하고 forged child/parent escape/양방향 overlap/overflow는 거부한다. Projected prepare는 stack-local non-authority
> candidate에서 모든 fallible 계산/검증을 끝내고 final destination write를 최초 publication으로 삼는다. 그 즉시 unchecked
> suffix가 final-address `ProjectedRecoverySnapshotCommit` 자체를 consume하며 이후 validator/abort/copy/move/reseal은 0이다.
> 모든 precommit failure에서 final destination, caller graph와 allocator-backed owner bytes가 불변이다. Resize equal-generation size equivocation과 target-stream mismatch는
> f3c1 pair 게시 전 기존 protocol-terminal preparation/consumer로 수렴하고 `invalid_precommit`과 구분한다. Component gate는
> Debug/ReleaseFast executable sentinel, branch one-field/copy/move/splice/replay,
> resize changed/generation/equivocation, resync candidate 0/1/64와 actual-token ABA, duplicate-after-success, max-ID 다음 admission
> wire 0, parent↔declared-child valid와 forged offset/parent escape, exact/양방향 partial/containing/adjacent/overflow range,
> callback reentry와 payload allocator `0x1`/side-intent output/
> binding source/disposition destination drift의 추가 dereference/free 0+bounded quarantine, final-zero를 고정한다. Older/equal
> resize success도 completed/correlation/receipt/payload를 exact once 소비한다. f3c2 boundary는 public consumer/새 decoder/request map/
> 두 번째 cleanup owner와 당시 product `pumpRxTurn` callsite 0을 확인했고, f3d boundary가 그 callsite를 exact 1로 전환한다. f3c2는 correlation idle+generation/digest와 branch
> state만 게시하며 새 input-gate bool, owner-authority flow, `TurnResult`를 소유하지 않는다. 실제 eligibility derive,
> f3d는 같은 held whole-turn lease 안에서 completed-control evidence를 resize/resync/terminal branch로 exact once 소비한다.
> resize는 canonical full-state만 authority로 쓰고, resync ACK는 기존 recovery reducer를 통해 `awaiting_snapshot`을 게시하며,
> malformed response는 기존 terminal binding/cleanup으로 수렴한다. 제품 orchestration 구간은 새 clock/allocator/socket/lease를
> 만들지 않고 branch 선택 뒤 일반 D2 TX authority를 다시 열지 않는다. consumed evidence와 semantic scratch를 모두 정리한 뒤
> authenticated destroyed intent tombstone만 outer-turn pristine으로 되돌린다. Component gate는 실제 `pumpRxTurn`의 세 경로,
> response cleanup callback owner drift의 invariant terminal+quarantine, forged tombstone field/digest/address 거부를
> Debug/ReleaseFast로 고정한다. hostile socket 순열, allocation fail-index와 stress는 f3e다.

> f3c0의 독립 merge gate는 `control_response_wire.zig` 하나가 allocation-free typed resize/resync request와
> strict response/error envelope를 소유하고, `RemoteRuntime`과 external pump가 각각 같은 decoder/encoder를 소비하는지
> 검증한다. external `admitControl`에는 raw JSON 입력이 없어야 하며 request encoder의 buffer cap-1/exact,
> malformed·duplicate·unknown·trailing response, allocator fail-index, expectation seal tamper를 Debug/ReleaseFast로 고정한다.
> blocking/external request는 같은 params vocabulary를 사용하고 resync wrong-kind expectation을 거부한다. filtered component
> tests와 codec/RemoteRuntime/external-pump component별 executable sentinel이 함께 green이어야 하므로 어느 component의
> zero-test 성공도 증거가 아니다. opaque whole-drain permit은
> storage/lease/incarnation, operation/turn/parser generation, parser absolute range/seal, sampled clock, authority seal/generation,
> completed owner/correlation과 TX queue generation을, verdict는 payload seal, request/control expectation/target, authority와
> permit digest를 미리 고정한다. private resync consumer 결과는 `consumed | stale | invalid | terminal`이며 constructor·public
> take·semantic apply 호출은 0이어야 한다. 이 gate는 정상 response 뒤 idle/recovery mutation을 증명하지 않는다.

> 2b2d2는 d2a pure classifier, d2b buffered/inherited bounded turn, d2c injected nonblocking
> read/admit, d2d RX-first whole-turn authority barrier를 모두 구현했다. 네 단계의
> Debug/ReleaseFast component, 실제 socketpair syscall-order 및 payload/ledger final-zero가
> 함께 green이며, d1 helper와 `client_pump.decide` unit fixture가 아니라 d2 product 경로까지
> 완료 증거에 포함한다.
> d2b는 d2b1(policy/readiness/whole-turn lease/O(1) inherited snapshot, 구현 완료),
> d2b2(compact provenance/all-or-none ledger live batch, 구현 완료), d2b3(persistent owners/intent scratch/buffered
> traversal/terminal-dominant aggregate commit)의 세 merge slice다. 세 slice 전체가 green이기 전에는 d2b 완료로
> 표시하지 않는다. 단건 prepared mutation을 순차 commit하거나 기존 callback-owning `mergeInto`를 d2에서 직접
> 호출한 증거는 aggregate atomicity 증명이 아니다.
> d2b1은 terminal/deadline 우선 blocker 표, parser readiness 1/31/32, stale/copy/cross-turn
> snapshot 및 committed screen/metadata summary lifecycle을 검증한다. 64/65의 실제 미소비 traversal과
> live screen summary는 persistent owner가 생기는 d2b3 gate가 검증한다. 구현된 d2b2는 compact range exact/cap/cap+1,
> old-end continuation과 overflow, ledger identity A→B→A 거부, provenance의 validate/relabel/merge/view/digest
> migration, 1 mutation zero-allocation hostile validation, 2/64 mutation fail-index all-or-none,
> legacy merge/release wrapper와 final-root disposition replay를
> 검증한다. 또한 source/allocator/content drift, callback-hidden allocation plan과 callback의 allocator/tail
> mutation, hidden-tail/count/cap+1 retirement,
> Debug/ReleaseFast와 128 KiB batch·192 KiB aggregate stack scratch compile-time 상한을 고정한다. d2b3은
> 1/64 completed screen의 token-only FIFO, cap+1 pre-consume 거부, partial/response exact-one
> owner, late terminal 전체 abort, callback-free FIFO advance/tombstone 선행, aggregate retirement callback
> 재진입과 count/byte cap을 검증한다. storage teardown은 live token을 별도 release하지 않고 기존 canonical
> screen/metadata/client/evidence/ledger freeze graph에 partial/response/live-screen owner를 함께 넣어 모든 owner
> tombstone 뒤 frozen local cleanup만 실행하는지와 final-zero를 검증한다.
> d2b3은 네 capability gate로 나눈다. d2b3a는 persistent owner header/blocker와 nonempty synthetic
> partial 1+screen 64+response payload의 teardown-first freeze/range proof/tombstone-first callback cleanup을,
> d2b3b는 d1 outcome→classified owner→caller-owned scratch exact move/abort/reset을, d2b3c는 ledger
> disposition→persistent owner/FIFO의 단일 no-fail aggregate commit core를, d2b3d는 inherited-first buffered
> traversal·FIFO release·partial lifecycle·response pending blocker·late-terminal whole-turn abort를 검증한다.
> d2b3a의 synthetic nonempty blocker는 true, teardown 뒤 canonical tombstone blocker는 false여야 한다.
> d2b3b의 caller-owned heap-pinned scratch는 별도 384 KiB compile-time 상한을 가지며 제품 stack 생성/copy는
> boundary상 0이다. d2b3c core는 기존 event/metadata owner까지 포함하는 product-compilable module-private
> 단일 구현이고, 이 gate 시점의 callsite만 test-only이며 export/제품 writer callsite는 0이다.
> d2b3d에서 partial/screen 제품 writer와 정상 consume을 함께 개방한다. response 제품 publish도 개방하지만
> inherited blocker와 teardown만 허용하며 exact take/correlation은 2b2f2에서 개방한다.
> owner가 nonempty 가능해지기 전 d2b3a teardown capability가 항상 선행해야 한다. d2b3d까지 전부
> green이기 전에는 d2b3 또는 d2b를 완료로 표시하지 않는다.
> d2c socket read 전 구조 분해는 별도 선행 gate다. `client_external_rx_turn.zig`가 sealed parser
> traversal과 partial transition만 소유하고 pump/storage/ledger/socket을 import하지 않는지,
> `client_external_pump.zig`에는 owner-held exact-one orchestration만 남는지 tokenizer boundary로
> 검증한다. 기존 d2b3d 제품 owner 통합 matrix를 유지하고 별도 leaf test root에서도
> header/partial/optional/1·64·65/late-terminal/allocation-alias hostile matrix를
> Debug/ReleaseFast로 실행하며, 두 matrix가 green이기 전에는 d2c
> socket callback을 추가하지 않는다. 구조 이동보다 먼저 `advanceValidatedPartial` exact-one 결과의
> before/after/header/range/identity가 classified intent seal에 포함되고 traversal이 sealed after만
> 소비하는지 고정한다. 외부 제품 owner→pump와 내부 pump→traversal callsite를 각각 exact-one으로 검사한다.
> d2c는 **설계 gate C0와 구현 gate C1~C3, C4a~C4d core integration 및 S3-D와
> C4 최종 SSOT·유지보수·보안 적대적 재감사와 C5 POSIX 제품 closure까지 완료**했다. C1은 split
> frame/read budget policy, Client parser provenance와 storage/lease에 이중 봉인된 resident cap,
> read DTO/constants/final-address scratch layout, 모든 positive limit tie와 accepted
> `< / == / >` stop 표를 고정한다. lease는 Client/parser 주소와 전체 provenance를 thread-local snapshot에도
> 봉인하며 positive consume의 unread 감소량과 buffer-start 증가량이 일치하고 parser generation이 정확히
> `+1`인 진행만 snapshot을 갱신한다. no-progress generation 재봉인은 거부한다. 일관되게 재봉인된 callback drift는
> terminal 복원, 복원 불가능한 descriptor drift는 bounded quarantine, teardown callback 뒤 cap/digest는
> canonical zero가 되는 hostile test를 포함한다. 이 증거를 Debug/ReleaseFast·boundary·전체 check로
> 고정한 뒤 C1을 merge한다. C2는 `ReplacementAllocationGuard.check`의 capture-before-allocation,
> validate-allocated, capture-before-cleanup, validate-after-cleanup phase와 value-only authority seal을
> 사용한다. allocation 반환 뒤 guard/alias/seal 검증 실패는 candidate write/free 0의
> `allocation_quarantined`, publication 뒤 old-backing cleanup drift는 canonical parser terminal의
> `post_commit_quarantined`다. cleanup은 allocator/range/seal을 frozen local로 옮기고 primary+mirror와
> allocator authority를 callback 전에 tombstone으로 만든 뒤 prepared를 다시 읽지 않는다.
> `FrozenReplacementCleanup`과 canonical `GuardedSourceSnapshot`이 callback 전 source/input/allocator/
> replacement authority를 동결하며, callback drift로 기존 parser backing을 잃는 경우에도 source capacity를
> bounded quarantine 상한에 포함한다. cleanup guard가 source를 변조한 뒤 거부하는 abort·precommit은
> replacement+frozen source capacity의 saturating aggregate를 exact once 보고하고 replay는 0이다.
> synthetic allocation fail-index, state/parser/prepared/input/
> old-backing/guard-context exact alias와 partial-state alias, overflow, OOM callback drift,
> replacement evidence 전체 삭제·길이 축소, invalid guard tag·zero/mismatched seal,
> allocator/guard reentry, primary/mirror/allocator/seal 독립 변조, moved/stale/double token,
> abort·precommit·postcommit callback drift, exact-one free와 no-free/exact-once 상한을 Debug/ReleaseFast에서
> 고정했다. tokenizer boundary는 guarded/legacy direct callsite가 mode 밖 0이고 기존 buffered product
> fixture의 `testing.admitBuffered` 세 callsite만 허용하며 pump/ledger/owner-range/global quarantine import를
> 금지한다. C3 injected collector와 completion/accounting gate는 구현했다. value-only
> `CollectResult`는 rejected/stopped/terminal을 분리하고 scheduling/parser 판정은 C4에 남긴다.
> receipt는 frozen allowance를 봉인하고 sealed borrow/stoppedBytes/settle API만 C4에 prefix를 넘긴다.
> ready→collecting→spent→borrowed→ready와 teardown-only terminal, current(pre)→read→current(post),
> stopped prefix 보존 대 terminal 전부 폐기, attempt 64/EINTR 9 우선순위, full-prefix scan 64 MiB,
> read 64/current 128 callback 상한, context extent와 callback-local protected range 16개,
> ordinary prepared tombstone의 mode-owned safe reset, quarantine latch accounting receipt를 요구하는
> 별도 finalizer 및 synthetic-only boundary를 Debug/ReleaseFast component와 ReleaseFast boundary로
> 고정했다. zero/nonzero parser backing, parser seal structural digest, pre/read/post hostile mutation,
> attempt permit 전 필드, protected range count/sort/overlap/overflow/partial leaf, stopped prefix 사후 변조,
> receipt/borrow alias·replay·settle mismatch, canonical terminal/teardown, ordinary/quarantine cross-finalizer,
> tag/phase/bound/cap/generation/replay와 같은-token 두 thread accounting event exact-one을 자동 검증한다.
> C4 private pump core와 S3-D의 leaf-owned prepared/consumed projection,
> pump-private prepare→arm→settle→consume lifecycle, fresh owner/blocker 재검증, finished exact reset은
> 구현했다. 이 core/projection과 현재 smoke·구조 경계는 Debug/ReleaseFast와 boundary에서 green이다.
> A는 pre-existing backlog를 buffered-first로 처리하는 동안 transport read/evidence 발급을 금지하고,
> B는 모든 positive complete frame이 owner backlog를 만든다는 protocol invariant를 고정한다. C의
> frame/read-budget stop, F의 실제 consume→publication→decide recorder, G의 same-address incarnation
> ABA·exact reset, leaf의 full pairwise exact/partial/adjacent/overflow matrix도 구현했다. E의
> consume/abort authority drift와 moved/stale/double 제품 matrix도 구현했다. C4 최종 적대적 재감사는
> 세 관점 모두 blocker 없이 종료됐고 CI의 macOS random-seed takeover fixture가 드러낸 잔여 출력
> 순서 의존성도 양 peer kernel RX·slot pending·producer remaining의 동일 quiescence 관측으로 닫았다.
> C5는 POSIX 제품 facade+실제 socketpair/pipe/adapter fixture로 마지막 구현 gate를 닫았다. `recv(2)`의
> positive/EOF/EAGAIN·EWOULDBLOCK/EINTR/other errno mapping, readable=false syscall 0,
> blocking fd에서 per-call `MSG_DONTWAIT`, positive 뒤 same-turn would-block, staged prefix 뒤 EOF publish 0,
> readable+writable에서 read-first·write 0, non-socket terminal/replay syscall 0, product `RxTurnOps`
> exact-one과 buffered-only facade 0을 Debug/ReleaseFast·boundary·전체 check로 증명했다.
> d2d는 **D0 whole-turn authority lifecycle, D1 RX prepare/publication 분리, D2 adapter
> abort/reset과 D3 actual socketpair/product hostile gate까지 구현**했다. D1은 공통
> `RxPreparedSummary` DTO, prepare 내부 scheduling decide 0, consumed drain evidence의 fresh
> owner/parser/lease/read-generation 검증→publication→exact-one decide→finish 순서를 고정한다.
> variant/terminal 불일치와 policy deadline terminal은 fail-close하며 semantic terminal은 held-lease
> stopped-read/drain cleanup 뒤에 latch한다. focused test는 non-default turn/deadline, terminal,
> frame/work budget, distinct counters, 모든 variant 조합, drained deadline reason/evidence/TLS/lease를
> 실행한다. settled tombstone hostile 표는 address·previous generation·seal과
> receipt stop↔seed↔permit lifecycle의 coherently re-sealed impossible 조합을 거부하고 실패 뒤
> scratch/receipt/borrow/use permit/seed/prepared-use mutation 0을 검증한다. D2는 scratch-owned
> permit/cleanup seed/turn generation과 최초 inherited snapshot digest를 고정하고, fresh current view로
> prepare→validate→abort→reset exact product lifecycle을 수행한다. cleanup descriptor corruption은 intact
> permit을 terminal tombstone으로 poison하며, stopped read/traversal/drain/callback TLS/quarantine receipt의
> 전체 closure를 entry·held-lease prepare·release 후 commit 경계에서 같은 predicate로 검증한다. lease release
> 성공 전에는 generation/ready를 commit하지 않는다. D3는 actual socketpair의 empty EAGAIN에서
> authority permit `prepare→validate→abort→reset` exact-one, positive/partial/inherited/terminal에서
> permit prepare 0, readable+writable RX-first와 peer TX 0을 검증한다. revoke 1/64/65와 optional
> unknown 64 뒤 revoke, `runtime.ended`는 lower screen/response/metadata/control/input/TX destination을
> commit하지 않고 aggregate를 abort한 뒤 typed terminal로 닫으며, product lower-publication snapshot과
> hostile owner/parser/drain/reentry drift 표가 이 경계를 고정한다. Debug/ReleaseFast
> `test-session-host`, `check-boundaries`, 전체 `mise run check`가 green이다. d2d는 완료했지만
> d2e~f3가 남아 있으므로 2b2 전체는 구현 완료로 표시하지 않는다. 2b2e는
> `e-core`(neutral incarnation-bound key, pure recovery reducer, generic consumer
> apply→release→mark, poll hint/fresh-clock wake)와 `e-integration`(f1/f2의 실제 TX
> offset·fully-sent·response-wait 증거를 사용한 충돌표 및 external owner 제품 배선)으로 나눈다.
> core만 green이면 2b2e 완료가 아니며 integration까지 green이어야 한다. 두 단계는 storage-owned
> consume과 attachment-owned charged release가 동시에 존재하지 않는지 boundary scan으로 증명한다.
> e-core는 null/exact/stale key, same-address reinit·cross-storage ABA, apply/release/mark 실패 순서,
> mark→latch→pollHint immediate, fresh-clock deadline-1/exact/+1을 Debug/ReleaseFast로 고정한다.
> e-integration은 origin 충돌표 전수, cleanup fail-index, 같은 zero-readiness turn의
> delta/invalidated/revoke, socketpair positions 1/64/65와 ledger final-zero를 제품 gate로 고정한다.
> 2b2f1은 f1a sealed admission/request-ID atomicity, f1b bounded write/clock/retire/cleanup,
> f1c held whole-turn authority/product socketpair의 세 internal gate다. f1a는 exact byte·item cap과 +1,
> checked overflow, request ID 1/max-1/max/exhausted, allocation fail-index와 allocator callback의
> queue/request/payload drift에서 Maru admission-owned publication 0을 검증한다. callback이 직접
> 바꾼 request/payload byte는 drift evidence로 남기고 rollback authority로 주장하지 않는다.
> zero/reserve policy의 request mutation 0/1,
> max-ID encode/OOM/stale rollback 뒤 exact reuse, allocation 성공 뒤 abort cleanup의 freeze→tombstone→free,
> null allocation·주소 산술 overflow·exact/partial protected alias에서 dereference/free 0과
> bounded quarantine를 검증한다. committed prepared의 same-scratch replay는 allocation/free와
> queue/request publication 0을 별도로 검증한다. allocator가 반환한 non-null 주소의
> mapped 여부는 Zig `Allocator` 계약 경계이며 런타임 probe 대상으로 주장하지 않는다.
> terminal 뒤 모든 admission의 allocation/request/wire 0도 포함한다. f1b는 1/64 FIFO, immutable offset-0 frame,
> partial resident 회계, short/full/EAGAIN/EINTR 8/9/zero/over-report/error, admission 30초와 head-progress
> 10초 deadline-1/exact/+1, queued-behind-head가 head 승격 전에 이미 absolute 만료한 경우의 write 0,
> backwards clock, queue generation max-1→max 뒤 live mutation 0과 max terminal teardown 1/64 exact cleanup,
> stale max permit replay·wrap 0, queued+retiring combined resident high-water,
> full retire·teardown의 freeze→tombstone→free exact once 및 same/cross-storage
> reentry를 검증한다. queue aggregate는 per-frame seal만 읽고 wire payload를 admission마다 다시 hash하지 않으며,
> 1 MiB frame의 1-byte short-write fixture가 digest/copy byte 예산을 초과하지 않는지 센다.
> allocator alias/invalid descriptor/cleanup drift quarantine는 storage sticky exact bytes와 process-wide
> event/byte high-water를 한 번만 charge하고 이후 facade 0, replay charge 0을 검증한다.
> f1c는 RX incomplete/backlog/budget/terminal에서 write 0, empty EAGAIN authority에서만
> write, callback drift 뒤 second write 0, turn wire-byte/frame exact cap과 Darwin socketpair
> short-write/EAGAIN/FIFO/final-zero를 검증한다. outer storage claim의 Client 조회 전 획득은
> source-order/boundary scan으로, held operation과 cross-thread teardown의 상호 배제는 deterministic
> barrier fixture로 검증한다. per-State operation/cleanup typestate는 제품 write callback의
> held/typed teardown busy, void cleanup bounded no-op, same-State cleanup exact once와
> unrelated-State 병렬 cleanup으로 검증한다. busy `Client.failClosed`는 owner/fd를 보존하고
> deferred close를 latch하며 operation release의 terminal 승격→canonical storage teardown으로
> typed cleanup exact once에 수렴해야 한다. outer terminal cleanup은 callback 전에 State cleanup
> claim을 예약하고 allocator callback의 operation 획득 0과 owner/FD cleanup을 검증한다. close
> request를 release load와 CAS 사이에 주입해 atomic `operation_close→idle_close` handoff와 lost
> wakeup 0을 고정한다. committed teardown은 Client value 이동마다 reservation address authority를
> 함께 이전하고 stale source callback의 operation 획득 0, 최종 owner/FD cleanup을 검증한다. 서로
> 다른 thread가 독립 예약한 두 State 사이 transfer는 process-unique reservation ID/source-address
> mismatch로 거부되고 각 owner cleanup 1회인지, destination의 `reserving` publish와 metadata 기록
> 사이 barrier에서도 transfer 0·양 owner cleanup 1회인지 검증한다. cancel은 `idle_close` 복귀·새 operation 0·후속 cleanup
> 가능인지 검증한다. busy
> void cleanup caller는 stable owner를 move/drop하지 않는다는 ownership 계약을 문서와 제품
> `ExternalPumpStorage`의 owner 보존→canonical teardown fixture로 고정한다. exact budget 뒤
> `immediate_tx=1→next turn EAGAIN→immediate_tx=0` no-spin, completion sink의 1/64 FIFO
> consume→spent·stale/replay/cross-storage와 scratch final-zero, final-byte retire callback terminal에서
> semantic sink 0·discard→spent를 포함한다. 세 gate가 모두
> Debug/ReleaseFast·boundary·전체 check에서
> green이기 전에는 2b2f1 완료나 제품 TX capability로 표시하지 않는다.
> C3 `snapshotDrainSeedAuthority`는 prepared/consumed phase의 exact address graph, private digest/range와
> attempt continuity를 callback 0/mutation 0으로 인증한 value-only projection만 반환한다. C4 pump는 raw
> receipt/borrow/permit/seed field를 재해석하지 않고 두 projection continuity만 비교한다. full final
> summary와 allowance stop은 evidence prepare 전에 확정하며, consume 성공 뒤 decide까지 terminal/budget/
> allowance/blocker branch, callback과 storage/scratch mutation은 0이다.
> C3 collector는 최초 `maxReadable` allowance 안에서 최대 1 MiB를 누적한다. allowance/would-block/
> attempt-budget stop은 validated staged prefix를 보존하고 EOF/error/EINTR-9/authority·descriptor·prefix
> terminal은 전부 폐기해 C4 admit 0이다. C4는 `staged_len>0`일 때만 guarded
> admit exact-one과 `traverseBuffered` exact-one을 실행한다. initial complete backlog는 traversal exact-one,
> zero-prefix would-block은 admit/traversal 0이다. allowance는 resident/turn/counter limit bit를 보존하고
> 각각의 terminal/immediate 표를 C1에서 고정한다. 기존 `TurnResult.rx_bytes`는 parser-consumed wire bytes,
> `rx_read_bytes`는 새 transport-accepted bytes로 분리한다. raw would-block observation은 admit/traversal 전
> parser generation을 authority로 쓰지 않고, final parser exact-empty/current lease·scratch·owner snapshot에서
> mint한 one-shot `RxDrainEvidence`만 같은 no-callback suffix에서 scheduling fact로 consume한다.
> C1~C5의 Debug/ReleaseFast component, hostile allocator/callback matrix, boundary, 실제 socketpair/pipe와 전체
> `mise run check`가 모두 green이고 SSOT·유지보수·보안 적대적 재감사도 blocker 0이므로 d2c를 구현으로
> 표시한다. 2b2d2 전체 완료 표시는 d2d까지 green인 뒤로 유지한다. d2c product deadline
> wiring은 입력 source가 생기는 d2e/f 범위이며 d2c는 null-deadline product와 pure deadline regression만
> 완료 증거로 삼는다. collector callback은 read 64, hostile authority 128, full-prefix scan 64회와
> staged-prefix validation 64 MiB analytic work cap을 갖고 65번째 read/129번째 authority callback은 0이다.
> C3 module의 pump/storage/ledger/traversal/POSIX/admit import·call은 0, product collector callsite는 0,
> dedicated synthetic test root만 exact-one callsite를 갖는다. outer scratch는 기존 structural 2 MiB+read backing 1 MiB+metadata
> 256 KiB의 exact 3.25 MiB compile-time cap이며 제품/fixture heap exact-one, stack/by-value 생성 0을 검사한다.
> limit bit 동률은 counter terminal → resident+incomplete resource terminal → turn immediate →
> resident+empty immediate 순서로 해석하며, C1 pure table이 단독·2-way·3-way와 accepted `< / == / >`
> allowance를 모두 검증한다.
> 현재 **d2b3a~d, d2c 진입 전 구조 분해 gate와 d2c POSIX 제품 closure는 구현**이다. 구조 분해 증거는 final-address
> `Scratch`의 generation/lifecycle seal, transport-independent exact-one `traverseBuffered`,
> dedicated test root, partial before/after intent seal, pump의 direct parser/moveFrame 0과
> tokenizer import/callsite allowlist다. d2b3a 증거는 private final-address owner 3종,
> 공통 `ResponsePayloadSeal`·`FrozenResponsePayloadCleanup`, partial 1+screen 64+response의 canonical aggregate
> teardown, 동일 `LiveOwnerBlockerProjection`의 true→tombstone false, descriptor/content/allocator drift의
> callback 전 거부, storage/cleanup scratch/ledger authority alias 거부, callback 재진입 차단, ledger/owner
> final-zero와 test-only activation assignment boundary다. 따라서 d2b3a 구현은 persistent owner를 제품 RX가
> 아직 publish·consume한다는 뜻이 아니며, 해당 제품 writer와 traversal은 d2b3d까지 0이다.
> d2b3b는 기존 `external_rx_demux.ExternalWireClass`의 accepted tag/candidate 전체를 owner seal에 포함해 후속
> 재분류와 candidate 복제를 0으로 만들고, d1 `.frame` payload를 allocator primary/cleanup mirror와 함께 exact
> once move한 직후 source를 tombstone해야 한다. copyable outcome의 source 주소를 credential로 오인하지 않고,
> attachment당 하나인 storage-bound scratch의 live-range disjoint+영구 replay watermark로 첫 copy 하나만
> ownership move를 허용한다. parser 권위는 같은 owner-thread facade의 outcome 직후/prepare 직전/tombstone
> 직전 view가 같아야 하고, owner generation은 scratch의 last generation보다 단조 증가하며 range end는 current
> parser watermark와 같아야 한다. 새 allocation은 heap-pinned scratch 1개뿐이므로 create callback 전후 authority
> 재검증, fail-index 0과 final-address sealed handle의 callback-hidden destroy가 전체 allocation gate다.
> abort는 64 owner 전체를 freeze/tombstone한 뒤 callback-hidden cleanup하며 unsafe drift는 arbitrary free 대신
> poison+bounded leak으로 수렴한다. poison 상한은 한 turn payload 1 MiB+scratch 384 KiB인 attachment당
> 1,441,792 bytes이며 기존 cross-owner quarantine status에 checked 합산한다. destroy는 callback 전 local
> reservation permit을 freeze하고 free callback 뒤 storage/handle을 재독해하지 않은 채 reservation 0과 canonical
> destroyed handle을 재게시해야 한다. `.incomplete`/`.skipped`는 move API 밖이고, ledger aggregate는 d2b3c sibling
> handle이 처음 소유한다. d2b3b 제품 callsite, storage/ledger/persistent owner publish와 제품 stack scratch는
> 모두 0이어야 한다.
> authority view는 aggregate proof SSOT와 같은 최대 22,560개의 start-sorted sealed pairwise-disjoint forbidden
> backing range를 운반한다. create/move는
> storage/handle/range-list backing과 이 전체 inventory alias를 거부하고, canonical teardown range proof는 scratch와
> 최대 64개 intent payload를 기존 Client/parser/ledger/live-owner 범위에 합쳐 검증한다. late protocol terminal은
> 기존 classified owner와 현재 payload를 모두 local freeze한 뒤 source/owner/scratch를 먼저 tombstone하고 callback을
> 실행한다. zero-length accepted payload도 allocator mirror를 보존한 정상 owner이며 abort/destroy에서 poison 없이
> 회수한다.
> d2b3b 증거는 file-private classified owner/scratch, heap allocation 1회의 fail-index 0, copied outcome
> first-move/replay watermark, screen/event/response classification value 보존, 실제 두 `current()` 사이 authority와
> source header/range/pair/content 및 same-bytes payload-pointer swap 거부, 22,560-range
> full-cap/hostile scratch·payload alias의 free 0, late terminal과 zero
> payload, bind/move/reset의 최신 inventory 충돌 거부, nonempty aggregate teardown, allocator free 재진입 거부,
> poison quarantine exact-once,
> Debug/ReleaseFast `test-session-host`와 function-local test-only boundary다. 제품 move/publish/stack scratch는
> 계속 0이며 d2b3d에서만 열린다.
> d2b3c는 현재 ledger `commitPreparedLiveBatch`를 outer aggregate에서 직접 호출하지 않는다. ledger 모듈이
> allocation/check/simulation/disposition을 끝내고 ledger mutation 0인 final-address `PreparedLiveCommit`을
> 만들며, exact-one aggregate callsite만 callback/error-free unchecked consume을 호출한다. intent 모듈도
> concrete scratch를 노출하지 않고 finalized whole-turn slot→destination과 exact payload move를
> `PreparedIntentCommit`으로 봉인한다. pump-private heap-pinned `PreparedRxAggregate`는 두 permit,
> batch/retirement/disposition과 destination plan만 결합한다. 기존 192 KiB ledger commit 예산을 재사용하고
> 별도 byte backing은 두지 않으며 wrapper allocation 상한은 256 KiB다. screen payload는 prepare-time
> `.screen_staging`에서 neutral move value→ledger batch로 exact move해 batch만 단독 소유하고,
> `PreparedIntentCommit`은 `.screen_mutation` slot과 event/response payload move를 봉인한다. permit은 실제
> private simulation 및 plan/output backing final address를 보유하므로 consume 때 재구성하지 않는다.
> aggregate는 attachment당 하나의 storage reservation을 가지며 trusted path는
> ready→preparing→finalized→committing→committed 또는 aborted→destroying lifecycle을 따르고 poisoned는
> reservation tombstone 뒤 destroy 금지 terminal이다. 전체 intent bijection, partial 최대 1,
> completed FIFO capacity/order, response 최대 1+기존 pending 충돌, metadata merge/retirement를 ledger mutation
> 전에 봉인한다. prepare/terminal/teardown 실패는 모든 cross-owner cleanup을 callback 전에 freeze하고 전부
> tombstone한 뒤 callback을 실행한다. 성공 suffix는 aggregate committing tombstone→ledger permit
> consume+mutation→intent permit consume+source tombstone+aggregate neutral slot move→sealed persistent
> owner write+neutral empty→aggregate committed→retirement 순서이며 첫 callback 뒤 authority 재독은 0이다.
> metadata current replacement는 별도 prepared replacement permit과 old-owner frozen cleanup을 쓰며 기존
> reducer의 older ignore, same+same cleanup-only, same+different terminal, newer replace를 그대로 따른다.
> poison은 두 reservation을 같은 held lease에서 poisoned tombstone하고 이후 destroy하지
> 않는다. 추가 quarantine 가산은 aggregate 262,144 + staged metadata 4,194,304 =
> 4,456,448 bytes이고 raw frame payload와 기존 current metadata는 기존 상한과 중복 계상하지 않는다.
> cross-owner frozen cleanup descriptor 상한은 ledger 128+intent 64+transfer 64+neutral 64+metadata 2=322이고
> callback-hidden local은 256 KiB compile-time stack cap 및 기존 aggregate callback-local 768 KiB cap에 동시에
> 포함한다. count/byte cap+1과 screen staging 각 선형화점, ledger prepare 실패/성공, intent neutral move 직후,
> destination write 직후 abort/teardown의 exact-one cleanup을 Debug/ReleaseFast로 고정한다.
> ledger `PreparedLiveCommit`은 phase별 final count, retirement output seal, simulation/disposition digest를
> 보유하고 prepare가 ledger mutation 0으로 preview한다. checked prepare/consume의 `LiveSimulation` local은
> 64 KiB cap, unchecked consume은 pointer read로 추가 copy 0이다. checked consume은 ledger-private이고
> module-public unchecked seam은 pump exact-one callsite 외 0이다. prepared permit abort는 dispositions unused와
> permit aborted를 먼저 만들고, consumed/aborted만 canonical reset할 수 있다. abort도 checked consume과 같은
> sealed batch/ledger/disposition validator를 통과해야 하므로 drift된 graph에서는 output/permit을 포함한 mutation
> 0이다. d2b3c 증거는 heap-pinned aggregate reservation의 allocation fail-index/callback authority drift,
> copied lease·copied intent handle, ledger/intent/destination seal·backing drift의 mutation 0, intent-index 고정
> writer 순서, response/metadata/resize/authority와 screen의 혼합 성공·late-terminal 전체 abort,
> classified→neutral-owned→ledger-owned→ledger-prepare-rejected→mutation-bound→finalized owner graph의
> teardown exact-one, intent→neutral→retirement cleanup과 committed destination teardown, cleanup descriptor
> exact 322/cap+1, Debug/ReleaseFast `test-session-host`, unchecked ledger consume exact-one 및 no-fail suffix
> 재분류·checked increment 0 boundary다. ReleaseFast suite는 macOS PR CI에서도 별도 실행한다.
> d2b3c callsite는 계속 module-private/test-only이며 제품 buffered traversal·FIFO consume은 d2b3d에서만 연다.
> d2b3d 증거는 exact-one 제품 owner wrapper와 실제 adopted `Client` parser→FIFO→consume fixture,
> committed-screen/metadata/resize 각각의 inherited-first parser·allocation 0, partial continuation과
> 1/64/65·late-terminal·response barrier·wire-order, callback retry/reentry 및 copied scratch/parser/owner drift,
> 모든 allocation fail-index와 callback-hidden cleanup이다. allocator 반환은 intent scratch/parser payload/
> aggregate 모두 raw address 단계에서 operation scratch·lease와 sealed full owner inventory를 검사하며,
> hostile whole-turn scratch·active intent·parser backing·misaligned address는 dereference/write/free 0으로
> quarantine한다. Debug/ReleaseFast `test-session-host`, boundary와 전체 `mise run check`가 green이다.
> full `RxRange`를 4,096 slot에 저장하는 구현이나 `ExternalPumpStorage` 512 KiB inline cap 증가는 허용하지 않는다.
>
> c3b 행의 `descriptor/len/cap/alias ABA`는 최종 상태 drift/stale-plan 검출을 뜻한다. A→B→A
> mutate-restore 이력이나 동일 주소·길이·byte allocator 재사용 검출을 주장하지 않는다. c3b는 판정과 준비물까지만
> 만들며 Client mutation·storage publish는 0이고, consume/cleanup/publish는 c3c combined commit이 독점한다.

> P5c3a observer 입력 SSOT: GUI observer backend의 `Unauthorized`는
> `SurfaceRuntime.InputSuppressed`로 변환한다. role cache 적용 전 own-stream revoke가 buffered된 경합을 포함해
> blocking key와 nonblocking paste/IME가 PTY write 0·trace input 0인지,
> paste error 분류가 `InputSuppressed`를 영구 폐기하고 `WriteFailed`/OOM은 재시도 대상으로 보존하는지
> Debug/ReleaseFast 테스트로 고정한다. resize는 canonical controller size를 따르는 local no-op이며, observer가 이후
> controller가 되어도 억제 시점의 과거 입력을 재생하지 않는다.

## 현재 자동 검증되는 영역

| 영역 | 현재 검증 방법 | 산출물 | 의미 |
| --- | --- | --- | --- |
| 기본 Zig 빌드 | `mise run build` | 없음 | 프로젝트가 Zig 0.16.0으로 컴파일되는지 확인한다. |
| 단위 테스트 | `mise run test` | 없음 | facade, config, terminal core 같은 작은 단위가 의도대로 동작하는지 확인한다. `PtyEventQueue`의 bounded capacity, close, event ownership, `RuntimeEventPump`의 queue drain/runtime 적용/해제 규칙, `LivePtySession`의 live PTY owner 계약과 `closeAndDetach`의 detach-first close 계약도 여기서 검증한다. 각 facade 배럴(src/*.zig)에 refAllDecls 집계 블록을 두어 구현 파일의 inline 테스트가 모두 빌드에 포함된다. |
| keybinding/terminal input 계약 | `mise run test` | 없음 | `KeyChord.parse`, app action과 terminal input macro 충돌 검증, unbound Cmd 조합 무시, `send_control`, `send_text`, `send_escape_sequence`, `Ctrl+letter` C0 control, `Alt/Option` meta-ESC 인코딩에 더해, **function key terminal encoding**(Home/End/Insert/Delete/PageUp/PageDown/F1~F12·DECCKM Home/End)과 **빌트인 macOS 줄 편집 바인딩**(`keybinding.default_terminal_bindings` — Cmd+←/→/⌫, Option+←/→; resolve 우선순위 사용자→빌트인→`.ignored`→encodeKey), **login(1) 래핑 구조**(`MacosLogin.build`의 `-flp <user> … exec -l`), **zsh 통합 env 주입**(`EnvStorage`의 `ZDOTDIR`/`MARU_ZDOTDIR_PREV` 덮어쓰기)을 검증한다. 물리 키 매핑(AppKit ABI KeyCode·`normalizedKeyEvent`)은 아래 *macOS Swift/Zig app host ABI* 행에서, login shell·zsh 편집키 통합의 실제 라이브 동작은 *interactive shell smoke* 행에서 본다. 수동 runtime config reload는 구현됐고 자동 파일 감지는 없다(kitty keyboard CSI-u 인코딩은 disambiguate 수준으로 구현됨 — 아래 *modifier/application-cursor 키 인코딩* 행). |
| headless E2E | `mise run e2e` | `tests/artifacts/e2e/headless/*.screen.txt`, `*.snapshot.txt`, `*.stdout.txt` | 실제 프로세스 stdout이 terminal core 상태로 변환되는지 확인한다. |
| recorded oracle 비교 | `mise run oracle` | `tests/artifacts/oracle/*/*.actual.txt`, `*.expected.txt`, `*.snapshot.txt`, `input.decoded.txt` | Maru의 화면 결과가 기록된 reference snapshot과 같은지 확인한다. 현재 golden은 사람이 손으로 기록한 기대값이며 실제 reference terminal 캡처가 아니다. |
| 빠른 스트레스 | `mise run stress` | `tests/artifacts/stress/quick/*.screen.txt`, `*.snapshot.txt`, `*.summary.txt` | 대량 출력과 반복 resize가 terminal core 상태를 깨지 않는지 확인한다. |
| 성능 예산 측정 | `mise run perf`, GitHub `Performance` workflow(`code` 변경 PR·main push·수동·주간) | `tests/artifacts/perf/core.txt`, CI `maru-performance-artifacts` | terminal core hot path가 보수적인 성능 guardrail 안에 있는지 확인한다. PR required check로 돌며, runner 변동은 여유 있는 예산으로 흡수한다([성능 예산](performance-budget.md)). |
| macOS PTY opt-in | `mise run pty` | `tests/artifacts/integration/pty/*.raw.txt`, `*.screen.txt`, `*.snapshot.txt`, `*.surface.txt`, `runtime-backpressure.summary.txt`, `reader-stop.summary.txt`, `interactive-shell.summary.txt` | macOS `openpty`가 controlled command stdout, process exit, resize를 실제 PTY로 전달하는지 확인한다. `SurfaceRuntime` 경로는 실제 PTY output이 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> Surface -> TerminalCore`를 통과하고, surface metadata artifact에 live handle/env가 새지 않는지 확인한다. 대량 stdout은 queue capacity 1로 marker count와 output event 수를 검증한다. reader close 경로는 출력 없는 long-running child에서 `PtyReader.stopAndJoin`이 blocking read를 정리하고 child를 reap하는지 검증한다. interactive shell smoke는 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL`을 `-i`로 실행하고 marker command를 PTY input으로 보내 raw/screen/snapshot/summary artifact까지 남긴다. app/demo/smoke 경로는 `LivePtySession` owner를 써서 정상 종료 뒤 cleanup이 중복 stop하지 않고, 조기 실패 경로는 아직 join되지 않은 reader를 같은 stop 순서로 닫게 한다. 환경 의존이라 기본 `check`에는 아직 넣지 않는다. |
| Windows ConPTY 백엔드 | `zig build test`(Windows 호스트) + `zig build check-targets`(모든 호스트, **컴파일 전용**) | 없음 | `src/pty/windows.zig`가 **진짜 자식을 띄워** 검증된다. 판정식은 마커 왕복이 아니라 **자식이 본 콘솔 크기 == `spawn`에 준 크기**다 — 자식이 pty에 안 붙어도(부모 표준 핸들을 물려받으면) 마커는 어딘가로 나오기 때문이다([windows-platform.md](windows-platform.md) §6). 대화형 왕복, `resize`, 종료 코드 수거, `close`, 그리고 **두 writer 동시 쓰기**(리더의 `writeInputNonBlocking` + 메인의 `writeInput`이 `OVERLAPPED` 하나를 공유한다)를 함께 본다. **이 행만 Windows 호스트에서만 돈다** — 저장소에 Windows CI 러너가 없다(사용자 결정). 그래서 OS 무관한 규칙(커맨드라인 인용·환경 블록·fixture 명령)은 `src/pty/windows_spawn.zig`·`src/app/fixture_script.zig`로 갈라 **OS를 인자로 받는 순수 함수**로 두었고, 그 테스트는 macOS·Linux CI에서도 두 갈래를 모두 돈다. **한계**: exec-restore(라이브 host 업그레이드) 표면은 구현이 아니라 **차단**이다 — `upgradeEligible`이 항상 false이고 `materialize`는 `@panic`이다(계약 §4·§8). 그리고 백엔드가 중립 레이어의 표면 합집합을 만족하는지는 **`check-targets`가 컴파일 전용으로** 지킨다 — `zig build test -Dtarget=…`는 게이트가 못 된다(외래 바이너리를 실행하려다 항상 실패한다). |
| headless PTY 데모 | `mise run demo` | `zig-out/maru-demo/headless-pty.screen.txt`, `.snapshot.txt`, `.summary.txt` | GUI가 붙기 전에도 실제 `PTY -> PtyReader -> RuntimeEventPump -> SurfaceRuntime -> Surface -> snapshot` 경로를 사람이 바로 실행해 확인한다. 테스트 실패 판정용이 아니라 개발 중 빠른 수동 확인과 디버깅 산출물을 남기는 경로다. **macOS와 Windows 양쪽에서 같은 artifact를 낸다** — fixture 명령만 OS로 갈리고(`src/app/fixture_script.zig`) 산출물 형식은 같다. |
| app host smoke | `mise run app-smoke` | `zig-out/maru-app-smoke/app-host.summary.txt`, `app-host.draw-list.txt`, `app-host.glyph-frame.txt` | 실제 UI는 아직 띄우지 않는다(`visible_ui=false`). AppKit/Metal 전에 `AppWindow -> SurfaceRuntime -> RuntimeEventPump -> RendererState -> DrawList -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` frame 조립, resize routing, focused input routing을 사람이 실행해 확인한다. `RendererState`가 persistent `GlyphAtlas`를 소유하고 backend 입력/UV/raster upload byte/skip 준비 artifact를 만든다는 계약까지 포함한다. |
| app frame loop smoke | `mise run app-loop-smoke` | `zig-out/maru-app-loop-smoke/app-loop.summary.txt`, `app-loop.frames.txt`, `app-loop.screen.txt` | 실제 UI는 아직 띄우지 않는다(`visible_ui=false`). `FrameLoop.tick`이 `RuntimeEventPump -> AppHostFrame -> RendererState -> RenderFrame` 순서를 반복 호출할 수 있는지 확인한다. 첫 output tick, queue가 빈 idle tick, exit event가 포함된 final tick을 같은 renderer state로 처리해 native AppKit loop가 나중에 같은 tick API를 호출하면 되도록 계약을 고정한다. 단위 테스트는 `FrameLoop.tickAfterDrainWithFrameBuilder`가 output, key input 뒤 output, idle, exit tick을 같은 주입형 builder와 renderer state로 반복 처리할 수 있는지도 검증한다. 이 smoke는 deterministic memory queue를 쓰므로 실제 PTY, window server, 물리 키보드, frame pacing은 검증하지 않는다. |
| live PTY app frame loop smoke | `mise run app-pty-loop-smoke`, `mise run app-pty-interactive-loop-smoke` | `zig-out/maru-app-pty-loop-smoke/app-pty-loop.summary.txt`, `app-pty-loop.frames.txt`, `app-pty-loop.raw.txt`, `app-pty-loop.screen.txt`, `app-pty-loop.snapshot.txt`; interactive shell은 `zig-out/maru-app-pty-interactive-loop-smoke/` 아래 같은 이름의 artifact를 남긴다 | 실제 UI는 아직 띄우지 않는다(`visible_ui=false`). 실제 PTY reader thread가 만든 event batch를 `RuntimeEventPump -> SurfaceRuntime`에 적용하고, 각 batch를 `FrameLoop.tickAfterDrain -> AppHostFrame -> RendererState -> RenderFrame`으로 만든다. 첫 event 뒤에는 빈 queue idle tick도 한 번 남겨 실제 app loop가 PTY event가 없어도 frame을 만들 수 있음을 증명한다. interactive variant는 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 실행하고 marker command를 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경계로 보내, shell input이 app frame loop 입력 정책을 통과하는지도 확인한다. PTY event drain은 smoke 전용 5000ms deadline을 가져서 reader/shell이 멈추면 `SmokeDrainTimedOut`으로 실패하고, 조기 queue close는 기존 lifecycle 실패(`ReaderQueueClosedBeforeTermination`)로 분리한다. 이 smoke는 실제 PTY와 반복 frame loop를 같이 검증하지만, AppKit/Metal window server, 물리 키보드, frame pacing은 아직 검증하지 않는다. |
| live PTY app host smoke | `mise run app-pty-smoke` | `zig-out/maru-app-pty-smoke/app-pty.summary.txt`, `app-pty.raw.txt`, `app-pty.screen.txt`, `app-pty.snapshot.txt`, `app-pty.frame.txt` | 실제 UI는 아직 띄우지 않는다(`visible_ui=false`). 실제 macOS PTY controlled command output이 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> AppWindow -> AppHostFrame -> RendererState -> RenderFrame`까지 통과하는지 확인한다. raw bytes, screen, structured snapshot, renderer frame artifact를 같이 남겨 PTY/routing/core/renderer 중 어디가 깨졌는지 분리한다. PTY event drain은 smoke 전용 5000ms deadline을 갖고 summary에 `drain_timeout_ms`를 남긴다. 이 smoke는 실제 shell bytes가 app host renderer frame으로 들어가는 첫 결합 검증이지만, 아직 AppKit/Metal window loop나 사용자 키 입력 event는 없다. |
| macOS visible window smoke | `mise run test-macos-window-smoke`, `mise run macos-window-smoke` | `zig-out/maru-macos-window-smoke/window.summary.txt` | display가 있는 macOS에서 실제 AppKit 창을 띄운다(`visible_ui=true`). 계약 테스트는 summary schema를 확인하고, visible smoke는 실제 window server/AppKit lifecycle을 확인한다. display가 없는 headless 세션(SSH, GUI 없는 CI)에서는 창을 보일 수 없으므로 `visible_ui=false`로 기록하고 non-zero로 실패한다. 아직 Metal surface, font, terminal grid는 없으므로 화면 내용 검증이 아니다. |
| macOS Metal product atlas sampling smoke | `mise run test-macos-metal-smoke`, `mise run macos-metal-smoke` | `zig-out/maru-macos-metal-smoke/metal.summary.txt`, `zig-out/maru-macos-metal-smoke/metal-frame.ppm` | display가 있는 macOS에서 실제 AppKit 창 위 CAMetalLayer에 제품 `RenderFrame`이 소유한 `GlyphQuadFrame/GlyphRasterFrame` 기반 cell quad를 present한다(`metal_surface=true`, `terminal_grid=true`, `glyph_text=true`). 이 cell quad와 raster bytes는 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> RenderFrame -> coretext_raster.zig` 경로에서 온다. `terminal_grid=true`는 입력 cell count나 non-clear heuristic이 아니라 `readback_samples > 0`, `atlas_sampled_cells == readback_samples`, `atlas_sample_missing_cells == 0`, `readback_failures == 0`일 때만 기록한다. readback sample은 cell center 고정이 아니라 source raster 안의 non-clear texel 위치를 cell quad 좌표로 매핑해서 고른다. 같은 smoke는 제품 `GlyphRasterFrame.uploads/pixels`를 Metal `RGBA8Unorm` atlas texture에 업로드하고 blit readback byte 비교까지 통과했을 때만 `product_atlas_uploaded=true`를 기록한다. upload가 0개인 all-skip frame은 upload/readback 실패가 아니라 sample source 누락으로 분리한다. 그 다음 fragment shader가 같은 atlas texture를 샘플링하고 drawable readback 픽셀이 source raster texel과 일치하며 `atlas_sample_missing_cells=0`이어야 `product_atlas_sampled=true`를 기록한다. `glyph_text=true`는 fixture 라벨이 아니라 `product_atlas_sampled`이고 그 frame이 실제 CoreText glyph bytes를 쓴 경우에만 도출되므로, 샘플링 증거가 없으면 거짓이 된다. 같은 drawable 전체를 PPM screenshot으로 쓰고 `screenshot_written=1`, `screenshot_failures=0`일 때만 `screenshot_artifact=true`를 기록한다. 계약 테스트는 summary schema, `NativeMetalCell` UV/atlas 소비, `NativeMetalRasterUpload` ABI, `NativeMetalSmokeResult` screenshot ABI, `renderer_input=terminal_core_draw_list`, `renderer_shaper=coretext_draw_list`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_frame_prepared=true`, `renderer_atlas_slot_placement=true`, `renderer_glyph_uv_ready=true`, `renderer_glyph_raster_ready=true`, `renderer_glyph_raster_skipped_count`, `product_atlas_uploaded`, `product_atlas_sampled`, `screenshot_artifact`, `atlas_sample_missing_cells`, atlas upload/readback/sample false case, screenshot false case, readback 없는 false/부분 readback false case를 확인한다. display가 없는 headless 세션(SSH, GUI 없는 CI)이나 window activation 실패에서는 `visible_ui=false`, `metal_surface=false`로 기록하고 non-zero로 실패한다. 이 static Metal smoke 자체는 PTY를 만들지 않으며, controlled PTY 연결은 별도 live PTY Metal smoke가 검증한다. |
| macOS live PTY Metal smoke | `mise run test-macos-app-pty-metal-smoke`, `mise run macos-app-pty-metal-smoke`, `mise run macos-app-pty-interactive-metal-smoke`, opt-in `MARU_APP_PTY_METAL_KEYDOWN_SOURCE=manual MARU_APP_PTY_METAL_KEYDOWN_MS=15000 mise run macos-app-pty-metal-smoke` | controlled smoke는 `zig-out/maru-macos-app-pty-metal-smoke/app-pty-metal.summary.txt`, `app-pty-metal.raw.txt`, `app-pty-metal.screen.txt`, `app-pty-metal.snapshot.txt`, `app-pty-metal-frame.ppm`; interactive shell smoke는 `zig-out/maru-macos-app-pty-interactive-metal-smoke/` 아래 같은 이름의 artifact를 남긴다 | display가 있는 macOS에서 controlled command의 실제 PTY output과 같은 Metal terminal window의 AppKit `keyDown:`에서 얻은 key event가 app host keybinding resolver를 통과하는 roundtrip을 `PtyReader -> PtyEventQueue -> RuntimeEventPump -> SurfaceRuntime -> FrameLoop -> coretext_frame_builder.zig(active AppWindow surface -> TerminalCore -> DrawList -> CoreTextDrawListShaper -> CoreTextGlyphRasterizer -> RendererState -> GlyphQuadFrame/GlyphRasterFrame) -> Metal atlas upload/readback/shader sampling -> screenshot artifact`까지 통과시킨다. 기본 실행은 CI/원격 개발에서도 재현 가능한 synthetic `Cmd+B`를 같은 Metal terminal window의 AppKit event queue에 넣고, manual opt-in 실행은 사용자가 같은 Metal terminal window에서 직접 누른 `Cmd+B`를 같은 resolver 경로에 태운다. `mise run macos-app-pty-interactive-metal-smoke`는 같은 executable을 interactive shell scenario로 실행해 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i` startup, marker command, `exit` output도 visible Metal path에 태운다. controlled input은 ready marker를 먼저 관측한 뒤 별도 `RendererState`로 만든 ready frame을 Metal terminal window에 그려 keyDown을 받고, 그 payload를 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput`으로 보낸다. 별도 state를 쓰는 이유는 key capture용 선행 render가 final frame의 glyph atlas cache를 오염시키면 새 native Metal texture에 upload가 누락되기 때문이다. interactive shell input은 prompt readiness가 환경마다 달라 marker command를 즉시 보낸다. drain은 smoke 전용 5000ms deadline을 갖고 summary에 `drain_timeout_ms`를 남긴다. final frame 조립은 `FrameLoop.tickAfterDrainWithFrameBuilder`가 `coretext_frame_builder.zig`를 호출하고, Metal fixture는 그 `RenderFrame`에서 투영한다. frame이 준비된 뒤에는 같은 Metal terminal window의 AppKit close delegate가 Zig callback을 호출하고, callback은 `FrameLoop.closeActiveLivePty -> host.closeActiveLivePty -> LivePtyRegistry.closeActive -> LivePtySession.closeAndDetach`로 내려가 active surface mapping과 `native_close_status=0`, `native_close_requested=true`, `native_close_callback_called=true`, `native_close_callback_status=0`, `native_close_window_closed=true`, `terminal_close_status=0`, `terminal_close_requested=true`, `terminal_close_callback_called=true`, `terminal_window_closed=true`, `close_surface_detached=true`, `close_registry_unregistered=true`, `close_late_output_rejected=true`, `close_input_rejected=true`, `close_queue_closed=true`, `close_idempotent=true`도 gate에 포함한다. `coretext_frame_builder.zig` 단위 테스트는 같은 builder 계약을 Objective-C 없이 fake bridge로 고정한다. `renderer_input=surface_runtime_live_pty_frame_loop_coretext_render_frame`, `interactive_shell`, `input_source=appkit_keydown_to_app_host_keybinding_resolver`, `frame_loop_ticks`, `frame_loop_final_tick_index`, `frame_loop_final_ended`, `close_lifecycle=appkit_terminal_window_close_callback_after_visible_frame`, `native_key_event_source=metal_terminal_synthetic_keydown` 또는 `metal_terminal_manual_keydown`, `native_keydown_received=true`, `scripted_key_event_sent=true`, `scripted_key_event_result=terminal_input`, `screen_contains_expected=true`, `product_atlas_uploaded=true`, `product_atlas_sampled=true`, `screenshot_artifact=true`, `glyph_text=true`가 함께 있어야 통과한다. 이 smoke는 실제 PTY bytes와 같은 Metal terminal window의 AppKit `keyDown:`으로 정규화된 keybinding-resolved terminal input bytes가 보이는 Metal UI까지 도달하고 같은 terminal window close delegate callback도 app host close action을 호출하는 검증이며, manual mode는 물리 키보드 한 번까지 확인한다. interactive shell mode는 prompt/dotfile 영향을 받는 실제 shell도 한 번 검증한다. 하지만 사용자가 계속 조작하는 제품 interactive shell loop, 제품 tab/window close button, full VT parser 호환성은 아직 검증하지 않는다. |
| macOS Swift/Zig app host ABI | `mise run test-macos-app-host-abi`, `mise run macos-app-host-abi-lib`, opt-in `mise run macos-app-host-swift-check` | `zig-out/lib/libmaru-macos-app-host-abi.a` | 제품 Swift app host가 호출할 C header와 Zig extern struct의 version/layout/ownership capability를 고정한다. `test-macos-app-host-abi`는 기본 Zig 테스트로도 실행되어 `app_host_abi.h`와 `app_host_abi.zig`의 ABI version, status/event 값, key/resize DTO 크기를 비교한다. `macos-app-host-abi-lib`는 Swift host가 링크할 Zig exported C ABI static library를 만든다. `macos-app-host-swift-check`는 macOS에서 `MaruAppHost.swift`가 `app_host_abi.h`를 import하고 AppKit 타입을 type-check할 수 있는지 확인한다. 이 row는 ABI/type-check 검증이므로 `NSApplication` 실행 여부는 별도 app shell row가 담당한다. |
| macOS Swift app host app shell | `mise run macos-app-build`, `mise run macos-app-smoke`, 수동 `mise run macos-app`, 수동 `MARU_SCREENSHOT=<path> mise run macos-app` | `zig-out/bin/maru-macos-app`, `zig-out/maru-macos-app/app.summary.txt`, `MARU_SCREENSHOT=<path>` PPM | display가 있는 macOS에서 실제 Swift `NSApplication` executable을 만들고, Zig ABI static library를 링크한 뒤 placeholder window lifecycle과 Zig-owned app session lifecycle을 함께 확인한다. Swift는 opaque session handle만 보유하고, Zig가 `LivePtySession`, `SurfaceRuntime`, `RuntimeEventPump`, `FrameLoop`, `RendererState`를 heap-pinned session 안에서 소유한다. placeholder view의 `keyDown`, window resize, window close는 fixed-width C ABI record로 Zig app session에 전달된다. smoke는 controlled PTY command를 실행하고 scripted key events와 scripted resize를 보낸다. controlled command가 입력을 받고 종료하면 `tick`이 `MaruAppHostStatusSessionEnded`를 올리고 Swift host가 frame loop를 멈춘 뒤 우아하게(exitCode 0) 내려간다(셸 종료를 못 보면 `MARU_MACOS_APP_SMOKE_MS` 1500ms fallback timer로 종료). 종료 시 summary에 `visible_ui=true`, `swift_host=true`, `abi_ready=true`, `placeholder_window=true`, `terminal_surface=true`, `terminal_surface_note=zig_runtime_rendered_to_swift_cametal_layer`, `metal_renderer_created=true`, `metal_frames_drawn`(>0이면 app session glyph가 창의 CAMetalLayer에 그려짐), `frame_loop_ticks`, `output_events>0`, `exit_events=1`, `key_events=2`, `terminal_input_events=2`, `terminal_input_bytes=2`, `resize_events=1`, `close_events=1`, `frame_prepared=true`, `final_frame_ended=true`를 남긴다. 수동 실행은 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 같은 Zig session에 붙이고, placeholder view가 받은 key event와 window resize도 같은 ABI로 내려간다. 이 row는 Swift launch, AppKit lifecycle, Zig ABI link, Zig shell surface/frame loop 결합, key/resize/close ABI 실패를 분리해 보기 위한 검증이다. app session은 fake font backend가 아니라 실제 CoreText shaper/rasterizer로 frame을 만들어 `glyph_count`/`atlas_entries`/`glyph_raster_ready`가 실제 rasterized glyph를 반영한다(CoreText 브리지는 macOS 빌드에만 들어가고 Linux CI는 tick의 macOS 분기를 comptime으로 제외해 fake backend 계약만 유지한다). Swift window의 content view는 `MaruMetalTerminalView`(CAMetalLayer)이고, 매 tick `maru_macos_app_session_metal_frame`의 cell/atlas/upload DTO를 lean 제품 Metal renderer로 그려 app session의 shell glyph가 실제로 보인다. 렌더는 fixed-cell pixel layout이라(#162) 창 크기에 따라 glyph가 늘어나지 않는다(창을 키우면 cell이 더 보임). resize cell 수는 실제 CoreText font metrics(advance×line-height)에서 Zig가 계산하고, 스크롤백도 휠/Shift+PageUp 뷰포트 스크롤로 동작한다(입력하면 live 복귀). 탭·선택/클립보드 같은 제품 interactive UX는 아직 검증하지 않는다. visible 픽셀 자체의 readback gate는 아직 없고(렌더 경로 실행은 `metal_frames_drawn`으로, 셰이더 정확성은 같은 셰이더를 쓰는 visible Metal smoke의 `glyph_text=true`로 간접 검증), 수동 `mise run macos-app`로 눈으로 확인한다. 제품 renderer 출력 frame은 `MARU_SCREENSHOT=<path> mise run macos-app`로 PPM artifact로도 남길 수 있다 — 창의 CAMetalLayer drawable은 `framebufferOnly=true`라 직접 readback이 안 되므로 같은 크기·픽셀포맷 오프스크린 텍스처에 같은 패스를 그려 blit readback한 뒤 smoke와 같은 `maru_ppm_writer.h`로 쓰고 프로세스를 종료한다(내용이 있는 첫 frame 한 장). 이 PPM은 사람이 눈으로 보는 시각 확인용이고 자동 골든 비교(시각 회귀 gate)는 아직 후속이다. |
| macOS CoreText font shaping/renderer-frame/raster smoke | `mise run test-macos-coretext-smoke`, `mise run macos-coretext-smoke` | `zig-out/maru-macos-coretext-smoke/coretext.summary.txt` | 창이나 GPU 없이 default raw config가 `ResolvedAppearance`로 검증되고, 그 font family/size 요청이 CoreText bridge까지 전달되는지 확인한다(`resolved_appearance=true`, `requested_font_family=...`, `requested_font_size=...`). 그 다음 macOS CoreText가 요청 font 또는 system monospace fallback으로 ASCII/CJK/emoji probe 문자열을 glyph run으로 shape하는지 확인한다(`font_resolved=true`, `shaped_text=true`). `requested_font_matched`는 요청 font가 실제 CoreText 결과와 이름/family 기준으로 일치했는지 알려 주는 진단값이며, 설치 폰트에 따라 0일 수 있다. `shaped_text=true`는 glyph count만 보지 않고 `ascii_glyph_present=1`, `cjk_glyph_present=1`, `emoji_glyph_present=1`, `missing_glyph_count=0`일 때만 기록한다. 또한 CoreText drawable glyph record의 PostScript name을 macOS `coretext_probe.zig -> coretext_font.zig` adapter와 `FontIdentityRegistry`에 통과시킨 뒤 `coretext_shaper.zig`가 renderer 중립 `GlyphRunList`로 바꾸고 `RendererState -> RenderFrame` 준비 계약에 넣어 `font_identity_ready=true`, `font_identity_count>0`, `glyph_frame_ready=true`, `atlas_keys_ready=true`, `renderer_frame_prepared=true`, `renderer_surface_cols/rows`, `renderer_shaper=coretext_shaped_records`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_glyph_raster_ready=true`를 확인한다. 추가로 실제 `TerminalCore -> DrawList` fixture를 native `CoreTextDrawListShaper`로 shape해 `drawlist_input=terminal_core_draw_list`, `drawlist_renderer_shaper=coretext_draw_list`, `drawlist_frame_prepared=true`, `drawlist_glyph_raster_ready=true`를 확인한다. `font_identity_count`는 공백 같은 비-drawable record를 제외한 실제 rasterizer 조회 대상 face 수다. 제품 후보 `coretext_raster.zig` wrapper가 같은 PostScript name으로 smoke native bridge를 호출해 제품 `GlyphRasterFrame` bytes를 만들 수 있는지 `renderer_glyph_raster_upload_count`, `renderer_glyph_raster_error_skip_count`, `renderer_glyph_raster_non_clear_pixels`와 `drawlist_glyph_raster_*`로 확인한다. 같은 `CTLine`을 CPU bitmap에 그려 `glyph_rasterized=true`, `raster_non_clear_pixels>0`인지도 확인한다. fixed probe surface는 native record bounds에서 만든 probe surface지만, drawlist probe는 실제 terminal size/cursor/dirty/overlay metadata가 CoreText shaper 경계를 통과하는지 검증한다. `coretext_probe.zig` 단위 테스트가 native record 변환을 검증하고, `coretext_shaper.zig` 단위 테스트가 explicit `ShapedGlyphSurface` metadata 보존과 DrawList shaper bridge를 검증하고, `coretext_raster.zig` 단위 테스트가 FontId -> PostScript name bridge 계약을 검증한다. 또한 `test-macos-coretext-smoke` 타깃은 ObjC `coretext_smoke.m`을 링크해 실제 네이티브 셰이퍼(`maru_macos_coretext_shape_draw_list`)로 box-drawing(U+2500)을 shape하고, 폰트가 글리프를 제공해도 합성 글리프가 `glyph_id=0`·codepoint cache_key로 정규화되는지(중복 슬롯·aliasing 방지) 회귀로 고정한다. 또한 이 smoke는 셰이핑 경로의 **누수 게이트**를 소유한다(`shape_leak_*`) — 합자 두 설정을 번갈아 4,000회 셰이핑해 순 footprint 증가가 상한(4MB) 안인지 본다. 정상 272~384 KB, `CFRelease` 를 되돌린 red 실측 72,024,112 B. 실패는 `MacosCoreTextShapeLeaked`, footprint 를 못 읽으면 `MacosCoreTextShapeLeakNotMeasured`, 셰이핑 자체가 실패했으면 `MacosCoreTextShapeLeakProbeFailed` 다. 셰이핑 결과 계약은 메모리를 새는지 알려 주지 않으므로 이 게이트가 별도로 필요하며, **화면에 증상이 없는** 회귀라 `.github/workflows/ci.yml` 의 macOS job 이 스모크와 계약 테스트를 함께 돌린다(`mise run check` 는 ubuntu 라 `.m` 을 컴파일하지 않는다). 단일 출처는 [폰트 전략](font-strategy.md) "셰이핑 경로의 메모리 소유권"이다. fallback run과 실제 resolved font name은 OS/font 상태에 따라 달라질 수 있어 pass/fail 조건이 아니라 진단값으로만 남긴다. 아직 설정 파일/설정 UI/runtime reload, Metal texture upload, Metal text draw, pixel-perfect 비교는 없으며 native CoreText raster 구현은 아직 smoke bridge에 있다. |
| macOS glyph texture upload smoke | `mise run test-macos-glyph-texture-smoke`, `mise run macos-glyph-texture-smoke` | `zig-out/maru-macos-glyph-texture-smoke/glyph-texture.summary.txt` | 창 없이 CoreText/CoreGraphics가 만든 CPU glyph bitmap을 Metal `RGBA8Unorm` texture에 업로드하고, 같은 texture를 blit readback해 source bitmap과 byte 단위로 같은지 확인한다(`source_rasterized=true`, `metal_texture=true`, `glyph_texture_uploaded=true`). 계약 테스트는 summary schema와 raster/GPU/upload/readback 단계별 false case(device 없음, status 비-0, readback 실패, byte mismatch, 0-ink 등)를 확인한다. Metal device를 만들 수 없는 headless/가상화/권한 제한 환경에서는 `native_status_label=metal_device_failed`, `metal_texture=false`, `glyph_texture_uploaded=false`로 기록하고 non-zero로 실패한다. 아직 shader sampling, atlas packing, AppKit window 위 실제 glyph text draw, screenshot artifact는 없다. |
| macOS glyph text shader sampling smoke | `mise run test-macos-glyph-text-smoke`, `mise run macos-glyph-text-smoke` | `zig-out/maru-macos-glyph-text-smoke/glyph-text.summary.txt`, `glyph-text-frame.ppm` | display가 있는 macOS에서 실제 AppKit 창 위 CAMetalLayer에 CoreText CPU glyph bitmap을 올린 Metal texture를 shader sampling으로 그린다. source glyph의 ink 픽셀 위치를 drawable 좌표로 매핑해 blit-readback하고, 선택한 모든 샘플이 clear 색이 아니며 배경과 luma가 충분히 대비될 때만(light/dark theme 모두) `glyph_texture_sampled=true`로 기록한다. 또한 drawable 전체를 PPM screenshot artifact로 남기고, screenshot이 쓰였을 때만 `screenshot_artifact=true`, `glyph_text=true`로 기록한다. 색은 `config.resolveAppearance`로 검증된 값을 쓴다 — `theme.background`를 Metal clear color로, `theme.foreground`를 CoreText glyph fill로 적용하고 readback 예측자도 같은 resolved background를 기준으로 삼으며, 적용 색을 `applied_background`/`applied_foreground`/`applied_cursor`로 남긴다(cursor 색은 resolve해 기록만 하고 아직 그리지 않는다). 계약 테스트는 summary schema, status label, visible UI/pipeline/readback/dark glyph/screenshot false case, resolved appearance 색 매핑을 확인한다. 이 smoke는 제품 terminal renderer, atlas packing, cell-grid text layout을 아직 증명하지 않는다. |
| renderer DrawList 계약 | `mise run test`, `mise run check` | 없음 | `RenderSnapshot`이 GPU/Metal 없이 backend-neutral `DrawList`로 변환되는지 확인한다. 현재 dirty 모델은 row 범위이므로 dirty row만 draw command로 만들고, wide glyph continuation cell은 별도 draw command로 만들지 않는다. cursor와 underline은 glyph가 아닌 overlay command로 검증한다. |
| fake font/glyph layout 계약 | `mise run test`, `mise run check` | 없음 | CoreText 없이 fake font backend로 `DrawList -> GlyphRunList` 경로를 검증한다. primary/fallback/replacement, combining mark, style/size/scale/color glyph cache key와 cursor/underline overlay가 renderer domain data로 보존되는지 확인한다. `FontIdentityRegistry` unit test는 같은 PostScript name의 `FontId` 재사용, 서로 다른 fallback face 분리, caller buffer 수명과 독립적인 name 소유, `font_id + glyph_id` cache key 분리를 검증한다. |
| glyph atlas/frame/quad/raster 계약 | `mise run test`, `mise run check` | 없음 | GPU texture 없이 `GlyphCacheKey -> AtlasSlot` domain cache/placement, `GlyphRunList -> GlyphFrame` 준비 계약, `GlyphFrame -> GlyphQuadFrame` UV 변환 계약, `GlyphFrame -> GlyphRasterFrame` upload byte/skip 계약을 검증한다. repeated key hit, raster-affecting key separation, row-packed slot 좌표 후보, upload byte 후보, eviction, invalidation reason, atlas slot reuse, frame upload 후보, cursor/underline overlay 보존, slot pixel rect -> normalized UV 계산, out-of-bounds slot skip이 `renderer_glyph_uv_ready=false`로 드러나는지, upload 후보가 contiguous RGBA bytes 또는 `GlyphRasterSkip`으로 회계 처리되는지, zero-ink 진단값이 남는지, `RenderFrame`이 raster upload identity와 byte range를 검증하는지 확인한다. |
| appearance config resolve 계약 | `mise run test`, `mise run check` | 없음 | 설정 파일 parser 없이 raw `FontConfig`/`ThemeConfig`/`CursorConfig`를 renderer가 소비할 `ResolvedAppearance`로 바꾸는 계약을 검증한다. 기본값, font family trim, font size 범위, `#RRGGBB` 색상 parsing, cursor shape/blink 보존, 깨진 색상 거부를 확인한다. |
| facade import 경계 | `mise run check-boundaries` | 없음 | terminal/renderer/plugin/pty가 금지된 레이어를 import하지 않는지 자동으로 확인한다. |
| macOS Mermaid helper lifecycle smoke | `mise run macos-mermaid-helper-smoke` | `zig-out/maru-macos-mermaid-helper-smoke/mermaid-helper.summary.json` | 실제 signed·sandbox nested helper의 반복 시작·timeout·재시작·종료 수명, closed entitlement 집합, whole-bundle seal, helper runtime exact digest/no-follow, path ABA의 child PID identity, digest exit 12의 1회 permanent latch를 검증한다. 정상 strict Mermaid는 API·CSP violation·top navigation 계수가 모두 0이어야 승인되고, 2.6초 지연 cold max-SVG도 5초 전에 accepted되어야 한다. 네 외부 API·DOM subresource·top navigation의 실제 probe는 각각 차단·계수된 뒤 render error만 반환한다. 같은 실제 `MermaidReplyDeliveryAdapter`와 ABI terminal drainer에 wrong identity, unknown/duplicate, timeout 순서 양쪽, targeted cancel, cap+1, pending A→B coalesce→A 즉시 terminal, 늦은 A exact-job revoke 뒤 B 보존, admission 전 fallback 미arm과 cold 5.25초/warm 2.25초 action-relative arm을 주입한다. helper와 smoke가 공유하는 `MermaidRendererPage.baseURL`의 nil 계약도 `blank_document_base_url_is_nil=true`로 고정한다. 실제 helper의 Launch Services 경고 UI 부재는 macOS 제품 환경에서 수동 확인한다. |
| macOS Mermaid 제품 성능 gate | `mise run macos-mermaid-perf` | `tests/artifacts/perf/mermaid-macos.json` | 실제 strict helper SVG와 제품이 쓰는 concrete `MermaidProductTickAdapter`·`MermaidAcceptedResultDrainer` 1,000 tick, exact 512 KiB accepted copy/decode 뒤 공용 `MermaidReplyDeliveryAdapter` pending lookup·response construction·one-shot callback·명시적 JSON 직렬화≤20 ms, terminal+accepted completion 합계 drain≤8, pending/source/SVG/terminal 98 cap, 3회 deadline restart·latch를 검증한다. process·pipe·blocking wait는 operation-site 계측으로 tick 귀속 0이어야 하고 build source-policy gate는 공용 tick/drainer 파일의 FS·WebView·process·pipe·sleep·blocking-wait API 유입을 거부한다. 메인 액터 tick의 `completionLock` 대기는 정상 경로(`product_tick_lock_wait_max_us`)와 hang/latch 경로(`failure_latch_product_tick_lock_wait_max_us`)로, hang/latch whole-tick elapsed는 `failure_latch_product_tick_max_elapsed_us`로 계측해 셋 다 ≤20 ms를 assert한다(정상·실패 경로 양쪽에서 worker wait 계약 증명). coalesce·deadline·transient·integrity terminal의 exact one-shot과 late timer/result 0, 100회 in-flight 편집 revoke의 helper start=1·마지막 결과 수락=1, terminal cap+1 mutation 0은 같은 coordinator·native adapter 회귀가 맡는다. `macos-app-smoke`는 실제 WKWebView provisional navigation 중 in-flight hang Promise 취소까지 보완하며 WebKit 내부 IPC serializer는 공개 주입점이 없어 실제 작은 SVG Promise E2E로 검증한다. |
| Markdown 읽기·소스 `.app` E2E | `mise run macos-app-smoke` | `zig-out/maru-macos-app/markdown.summary.txt`, `markdown-preview.md` | signed `.app`에서 **제품 흐름 그대로 두 모드를 왕복한다.** ⑴ 읽기 모드에서 격리 render origin이 Mermaid 펜스를 발견해 `maru.file.renderMermaid`→wire v2 helper→sanitized SVG 왕복을 마치고(`file_viewer_mermaid_request=ok`), 같은 문서에서 터미널 테마 syntax 색·선택 색·편집기 폰트 크기가 실제로 주입됐는지 inline style로 확인한다(§2.3 — app.css의 `:root` 폴백은 inline style에 안 나타나므로 값의 존재 자체가 native 도달의 증거다). ⑵ Zig mode 설정 export로 소스 모드에 들어가 실제 CM6 first responder에 AppKit 글자 입력을 보내고, 실제 `⌘S`의 `WebKeyRoute.web_editor` 판정과 disk marker를 단언한다(JS synthetic save·smoke 전용 bridge write는 쓰지 않는다). ⑶ 다시 읽기로 돌아가 isolated bridge의 test-only hang을 helper에 제출하고 in-flight에서 실제 `WKWebView.reload()`을 호출해 `didStartProvisionalNavigation`이 pending reply를 남기지 않는지 본다(`mermaid_pending_replies=0`). helper start/request/result는 시나리오 길이에 따라 늘 수 있어 bound로 두고 deadline 1건과 pending 0만 exact로 고정한다. 마지막 reload는 editable recovery latch를 의도적으로 세우므로 저장 검증 뒤에만 실행한다. 스모크는 전용 HOME으로 격리해 사용자 workspace 복원이 결과를 흔들지 않게 한다. HTML smoke가 공용 `app.summary.txt`를 덮기 전에 Markdown summary를 별도 보존한다. |
| 전체 확인 | `mise run check` | 위 산출물 전체 | fmt-check, unit, E2E, oracle, stress, boundary, build를 한 번에 확인한다. |

## 구조화 스냅샷

`*.screen.txt`는 사람이 보기 좋지만 터미널 내부 상태를 모두 증명하지 못한다. 그래서 `*.snapshot.txt`는 `RenderSnapshot`에서 다음 상태를 함께 기록한다.

- 화면 크기
- 커서 위치와 표시 여부
- dirty region
- 각 row의 셀 텍스트
- wide/continuation/combining cell metadata
- non-default style이 있는 셀 목록

이 포맷은 현재 테스트 산출물이면서, 나중에 replay trace와 inspector가 같은 도메인 데이터를 보도록 하기 위한 첫 관측 가능성 경계다.

fixture, golden, trace 파일의 저장 규칙은 [Fixture와 Oracle 포맷](fixture-format.md)을 따른다.

GitHub `CI` workflow는 `mise run check`와 외부 오라클 실행 후 `tests/artifacts/**`를 각각 `maru-check-artifacts`, `maru-external-oracle-artifacts`로 업로드한다. 실패했을 때 로그만 보는 대신 실제 screen/snapshot/summary를 내려받아 원인을 확인하기 위한 장치다.


## 아직 완전 자동 검증이 아닌 영역

불가 이유는 다음 의미로 쓴다.

- `구현 전`: 기능이나 테스트 러너가 아직 없어서 못 검증한다. 만들면 자동화할 수 있다.
- `환경 의존`: 외부 바이너리, SSH 서버, macOS window server, GPU driver, font stack처럼 실행 환경에 따라 결과가 달라질 수 있다.
- `시스템 한계에 가까움`: 순수 headless 테스트만으로는 실제 화면이나 하드웨어 동작을 완전히 증명하기 어렵다. 대신 내부 snapshot, screenshot, 수동 산출물을 함께 남긴다.

renderer capability의 현재 검증 계약은 `editor_epoch`를 포함한 `RendererCapability` 6-field 공용 alias이며, epoch를 포함한 어느 필드든 stale이면 fragment 재사용·DOM 높이 변경이 0이어야 한다.

### C3-3b2a·b2b 세부 gate

- **C3-3b2a process-seal prerequisite(구현):** focused gate `test-session-host-2c3d-c3-3b2a`가 neutral
  `process_identity` PID SSOT, `process_seal_service`, ClientSlot bootstrap ready-last transaction과 `operation_thread_identity` capability key source-level cutover를
  Debug·ReleaseFast로 검증한다. 구 key/storage/lazy init/API/callsite는 0이다. neutral cryptographic entropy provider는 service unpublished private storage에
  직접 쓰며 byte OR zero는 permanent terminal이고 issuer/registry/ready publication 0이다. local service test scalar seed input/output zero,
  concurrent first init/pause boundary, same-domain idempotence, fork-without-exec inherited-key pre-lock rejection,
  두 clean-process non-test helper의 public singleton bootstrap·same-process derivation idempotence·process 간 derived tag 비재사용,
  domain cross-replay와 기존 capability/reader/closing/pin 전체를 상속한다. lifecycle은
  `uninitialized -> initializing -> ready | terminal`이고 initializing claim 뒤 모든 실패가 terminal release를 게시하는지, zero 검사가
  registry/issuer work 전에 실행되는지 검증한다. old domain/tag replay, raw key·generic MAC API·test reset, 구 storage/API와 fatal primitive의
  비허용 caller는 source boundary에서 0이어야 한다. exact package-private API/error set과 ClientSlot의
  `ProcessDomainMismatch|ProcessSealUnavailable` 정규화를 전수한다. process identity 1개, local service 8개, product fresh-exec oracle 1개,
  product bootstrap 1개, PID authority fork 3개와 source boundary 1개를 Debug·ReleaseFast로 실행하고 fork child, 두 clean exec, publication pause,
  invalid/replayed receipt direct fatal을 포함한다. ordinary
  non-Darwin native CI의 initialization과 capability
  publish/consume도 같은 provider abstraction으로 실행하며 non-secret fallback과 강제 test seed가 없음을 고정한다. Linux의 Client fence,
  generation transport, initial snapshot owner, generation batch allocator-scope registry와 ended-purge quarantine receipt/proof는 실제 PID
  SSOT를 사용하고 unsupported target은 zero PID로 닫으며 fork child가 inherited
  authority를 lock/graph 접근 전에 거부한다. source boundary는 의미론적 PID authority의 legacy `macOS ? getpid : 1` 계산을 0으로 고정한다.
  b2a는 capability 전용 API만 내고 cleanup transcript/progress typed method는 b2b가 추가한다.
- **C3-3b2b0 exact observation(구현):** focused gate `test-session-host-2c3d-c3-3b2b0`는 공용
  `RuntimeObservation.replace`가 0/1/near-cap 입력과 빈 progress 보존에서 모든 owned list를 exact capacity로 만들고, progress 소비 뒤에도
  backing을 해제해 zero-length owner는
  canonical `.empty`를 유지하며, 모든 allocation fail index에서 기존 snapshot을 byte-for-byte 보존하는지 Debug·ReleaseFast로 검증한다.
  `replace` API와 caller topology는 그대로 사용한다. progress 소비 API는 allocator를 받아 backing까지 해제하도록 의도적으로 바꾸지만
  session-host pending owner·event lifecycle·제품 caller delta는 0이다. semantic test 3개와
  app aggregation sentinel 7개, source boundary 1개를 Debug·ReleaseFast로 실행한다.
- **C3-3b2b1 trusted preparation seal prerequisite(구현):** focused gate `test-session-host-2c3d-c3-3b2b1`은 기존
  `GenerationEventTrustedView`를 변경하지 않는다. ClientSlot exact-correlation validator가 quarantine mirror의 take-time
  `expected_major|metadata_support`, canonical event/correlation binding digest와 fixed owner identity의 pointer-free instantaneous projection을
  만들고, private identity를 소유한 generation-event contract가 이를 기존 borrowed `EventOwner.view()`와 별도 필드로 조합하며
  GenerationTransport가 그 seam만 호출한다. current Client capability 재조회, opaque correlation의 projection 반환·저장·raw accessor
  accessor, 저장 가능한 두 번째 take DTO, allocation, `RemoteRuntime` field와 normal product caller는 0이다. process seal은 named fixed-shape
  `preparation = DTO backing + next observation 7 owners`와 `committed_observation = old observation 7 owners` typed input만 받아 distinct versioned
  domain의 full 32-byte transcript/progress seal을 만든다. neutral 9개·service 8개·projection 1개·boundary 1개를 exact-count로 실행해
  every-field/domain/role/order/attempt/progress replay, PID/ready/fork, transcript·progress·string·foreground·observation golden vector,
  fixed-fatal rejection, constant-time compare, generic writer/MAC·raw key·permit registry·persistent mirror 0과 repo-wide source/import/caller
  inventory를 Debug·ReleaseFast로 고정한다. projection 21개 필드의 이름·순서·타입과 recursive pointer/slice 부재를 comptime으로 고정하고,
  exact projection validation 중 재진입이 `Busy`이며 operation 종료 뒤 재조회가 성공하는지 검증한다. recoverable canonicality probe는 test
  binary에만 있고 제품 service는 fatal-only assertion을 쓴다.
- **C3-3b2b2 pure preparation recipe(구현 완료):** focused gate `test-session-host-2c3d-c3-3b2b2`는 pointer/slice/allocator/function/
  owned storage 0인 pointer-free fixed-field `EventPreparationRecipe`, raw-first metadata scalar/presence, metadata size/two-pass fill과 pointer-free
  fill projection을 고정한다. outer tag만 explicit `u8`이며 재사용한 `Violation`/resize nested layout을 serialization ABI로 주장하지 않는다.
  `runtime_event_types.classifyEventView`는 유일한 classifier로 signature·본문·caller delta 0이고, constructible `Classification`은 authority가
  아니다. compatibility wrapper의 immediate classifier result와 future b2b3 trusted staged wrapper만 provenance를 소유한다. metadata는
  canonical lexical reparse+exact preflight/recipe equality로 same-digest scalar/span/presence/process forge를 allocation·fill 전에 거부한다.
  기존 `classifyAndMaterializeEvent` parameter/result shape·sole `RemoteRuntime` caller와 기존 `DecodeError` member 의미는 유지하되 event facade의
  `EventMaterializationError`만 `LocalInvariant` 하나를 추가하고, allocator callback 뒤 full source를 재검증한다. fill은
  payload/recipe/backing/process의 checked pairwise nonoverlap과 모든 span/process를 첫 write 전에 검증하고 반환 직전 payload digest를 다시
  확인한다. pre-write error는 backing/process byte-preserving이고 post-fill final-digest error만 scratch가 unspecified일 수 있으며, 둘 다
  DTO/pending/Runtime publish는 0이다. nonzero failure는 adapter free 1, success는 DTO transfer 1과 later deinit free 1, zero는 alloc/free 0이다.
  accepted 뒤 builder/fill failure와 callback 뒤 source drift·destination/final-digest integrity failure는 `EventMaterializationError.LocalInvariant`를
  거쳐 sole caller의 `.local_invariant_violation`으로 가며 peer failure로 오분류하지 않는다. legacy `DecodeError`에는 새 member가 없다.
  violation과 non-metadata accepted는
  allocation 0, metadata zero backing은 0, nonzero는 exact allocation 1, OOM은 시도 1/publish 0이다. recipe semantic 10개+compatibility adapter 5개+RemoteRuntime mapping 1개+
  boundary 1개를 Debug·ReleaseFast exact-count로 실행해 accepted 5개, frame 8·identity 5·authority 2·capability 1·foreign 2와
  `stale_preflight|unknown_event|malformed|resource_exhausted`,
  overflow, escaped string, SSH absent/present-empty, foreground canonicalization, raw 0/1·enum/mode 범위와 DTO equality를 고정한다. source raw span은
  recipe에 저장하지 않고 canonical reparse 한 호출에서만 쓰며, primitive process cap/value type은 `runtime_metadata_types`가 단독 소유한다.
  pure leaf는 `resize_wire.Event`를 위해 `resize_wire.zig`를 명시적으로 import하고 이를 감추는 barrel re-export는 0이다. 그 밖의 `RuntimeObservation`/allocator/
  owned DTO import, reverse import, barrel re-export, current external staged 재분류, b2b3 staged/product caller와 `RemoteRuntime` field는 0이다.
  compatibility footprint만 보존하며 next/old observation과 4-part budget, 최종 owned `PreparedEvent` 완료는 주장하지 않는다.
- **C3-3b2b3 immutable owner preparation(구현 완료):** focused gate `test-session-host-2c3d-c3-3b2b3`은 production-source dormant orchestration을
  Debug·ReleaseFast test mode에서 real `GenerationAttachment` take부터 trusted projection·snapshot·recipe·final-address owner publication까지
  호출한다. normal product pump caller는 0이다. final-address/copy/replay, every copy ordinal OOM, exact-capacity 4-part prepare peak와 3-part
  published rehash, non-exact old cache 거부, reduced failure, queue/content guard, allocator callback drift/alias/provenance, final `PreparedEvent`
  handoff를 고정한다. 구현은 prepared types 7+lifetime 1+owner 7+preparation 10+hostile 5+fork/proof-loss/abort subprocess 3+
  callback-class 독립 subprocess 1+runtime control 1+queued control 1+real-take adapter 2+boundary 1의 unique exact-39와 canonical adapter fresh replay 1,
  즉 최적화 모드당 actual exact-40 실행이며 non-test topology sentinel은 별도 source assertion이다.
  callback-class는 여섯 authority mutation 외에 DTO free 중 retained observation content 변조도 fresh artifact의 child callback으로 실행하고 부모가 `_exit(86)`을 고정한다.
  전체 session-host 및 기본 core/exe aggregate는 이미 초기화된 process seal을 fork로 상속하지 않도록 이 DTO probe만 exact-filter fresh artifact를
  Debug·ReleaseFast 선행 실행한다. aggregate copy의 중복 fork 제외는 mutable environment marker가 아니라 compile-time test count로 결정하며,
  fresh artifact는 runner의 `--maru-expect-tests=1`로 exact-one 선택을 별도 검증한다.
  real-take adapter는 canonical metadata event의 실제 nonzero allocation 다섯 ordinal OOM과 fail-index 5 최초 성공을 실행한다. 별도 real-take 거부표는
  operation Busy, source-view drift, destination snapshot invalid의 세 preflight가 pending owner와 source view를 바꾸지 않음을 검증한다. 성공행은 source lease consumed,
  release receipt live, lifetime idle, retained cleanup graph·persisted progress/transcript input·exact metadata를 검증하고 publication 뒤 content drift는 borrow를 거부한다.
  real-take gate는 source·operation·destination preflight 전 registry mutation 0,
  begin no-fail suffix 첫 mutation의 exact active `EventAuthority live -> preparation_pending`, pending 동안 canonical view 유지와 ordinary
  release·attachment teardown·ended purge의 `Busy`를 함께 검증한다. 별도 pending registry/owner-address row는 0이고 b2b3 제품
  `preparation_pending -> live|releasing` caller도 0이다. fixture cleanup은 owner가 저장한 progress/transcript seal input, graph, allocator provenance와
  observation content를 같은 private validator로 검증한 test-only discard 뒤 exact identity를 재검증한 pending→live rollback과 기존 release를 수행한다.
  b3 gate가 exact release receipt 기반 sole product pending→releasing caller를 추가한다. publication 당시 봉인된 transcript/progress seal을 cleanup entry에서 검증한 뒤 callback-inaccessible stack mirror로
  복사하고 protected range에 포함한다. proof exact이면 reverse exact-once cleanup 뒤 fatal, proof loss면 remaining dereference/free 0,
  addressless evidence 0~1과 direct `_exit` subprocess로 닫는다. 48행은 8 ordinal×6 authority class의 seal sensitivity 전수이고,
  별도 실제 callback subprocess가 role-independent validator의 여섯 authority mutation class를 각각 `_exit(86)`으로 고정한다. 12행은 네 lease state×세
  authority drift validator 전수이며, 23행은 제품 entry inventory의 static boundary와 3 read-only/16 Busy/4 copied-owner lifetime decision을 결합한 증거다.
  실제 settlement와 Busy retry는 b3, close readiness는 b5, product activation은
  b4가 소유한다. umbrella `test-session-host-2c3d-c3-3b2b`는 b2b0~b2b3 focused gate 전체를 상속하며 이 범위의 완료 증거다.
  b3 focused `test-session-host-2c3d-c3-3b3`은 기존 b2b umbrella를 상속하고 Debug·ReleaseFast에서
  final-address settlement lease의 prepare/second-settlement 상호 배제와 close-kind reserved compatibility,
  original owner+lease 검증 없는 binding 단독 권위 0, paired arm 단일 no-fail suffix의 lease `prepared -> admitted` 뒤 Pending `prepared -> settling`, exact pending receipt 기반
  `preparation_pending -> releasing -> idle`, none·poison·revoke clean/cancel/partial→poison·already-terminal의 closed plan,
  PRE one-shot plan/POST exact validation, optional reason ordinal-0 구분, unusable 전후, outbound absent/target/sibling와
  absent/preserved/freed/cancelled/partial disposition의 canonical matrix를 검증한다. revoke sibling은 byte/address/offset을 보존하고
  poison/terminal은 connection-owned descriptor를 exact 0|1회 정산한다. deferred terminal fd는 callback 전 detach하며
  direct no-retry close-attempt exact 1, allocator cleanup exact 0|1과 fixed close-before-free schedule을 검증한다. same-owner pre-admission Busy는 세 호출 모두
  mutation 0이고 네 번째 호출만 같은 attempt로 성공해야 하며 내부 retry/yield는 0이다. copy/move/cross-owner/fork/ABA/replay,
  one-field receipt/effect drift, callback reentry, allocator callsite 0과 exact-proof/proof-loss `_exit(86)` subprocess를 포함한다.
  boundary는 Attachment의 Runtime semantic import 0, 일반 live release 계약 변경 0, persistent per-stage done/effect/registry
  mirror와 두 번째 cleanup owner 0, sole sealed `SettlementDisposition` exact 1, b3 normal product pump caller 0,
  b4-owned semantic publication/reset caller 0을 고정한다. close compatibility는 기존 ordinal
  `none=0/preparation=1/close=2` 불변, 새 `settlement=3`, raw close 상태에서 settlement acquire `Busy`인 sealed fixture와 unknown
  raw tag mutation-0 거부까지만 검증하며 실제 close acquire 경쟁은 b5에 남긴다. 실제 product event pump와
  `settling -> committed_cleanup -> idle`은 b4 증거이므로 이 gate만으로 C3-3b 완료를 주장하지 않는다.
  output별 non-pristine, exact/양방향 partial overlap, cross-output/permit/owner/lease/Client/registry alias, same-address output ABA,
  disposition outside-owner/wrong-inline-offset/other-owner same-offset/canonical field 밖 owner-subrange overlap,
  prepared-before-seal·one-field-unwritten·partial publication은 authority 0으로 거부한다. attachment paired preflight의
  first/second failure는 permit/output pristine이고 Pending preflight failure는 paired permit exact pre-admission abort 뒤 lease
  abort를 검증한다. low-level admit의 paired arm 밖 product caller 0, admitted lease의 abort와 prepared lease의 consume은 proof loss이며 product post-admission abort caller 0이다. boundary는 coordinator의 direct
  ClientSlot/registry import와 raw pointer getter 0, attachment/transport의 canonical projection exact-one을 함께 고정한다.
  pure scratch-range preflight는 lease/evidence/permit pairwise 및 lifetime/Pending/attachment protected-range 관계를 integer-only로
  검사한다. non-pristine, exact·partial alias, disposition wrong containment, copied/moved destination과 same-address stale storage는
  acquire 전 `InvalidOwner`, owner row/counter와 모든 scratch byte mutation 0이다. range proof 뒤 byte drift-before-pristine과
  pristine proof 뒤 `lease_out` drift-before-acquire는 counter mutation 0이다. 그 밖의 scratch drift-after-pristine과 acquire 뒤
  drift-before-final-preflight는 attachment/Pending final preflight의 exact abort+incarnation burn으로 분리하고 성공 lease는 original
  final address에서만 abort/consume 가능한지 검증한다.
  preliminary precheck 뒤 경쟁 prepare/settlement exact finish와 same-address next-attempt race는 lease 아래 final preflight에서
  typed reject하고 process 생존·domain mutation 0·operation incarnation burn만 검증한다. RED inventory는 최적화 모드당
  unique component 36개와 product-prepared coordinator fresh replay 1회,
  fresh subprocess 5개(pre-admission fork, post-admission proof loss, post-callback proof loss,
  Client POST callback drift, watchdog), boundary 1개다. watchdog은 marker 전 무응답, prefix 뒤 열린 pipe,
  EOF 뒤 child 생존, 정확히 16-byte를 쓴 뒤 정상 EOF와 exit 73, cap 뒤 trailing marker, signal 종료를 typed
  observation으로 분리하고 deadline 행은 exact `SIGKILL` wait status를 요구한다.
  각 artifact는 `--maru-expect-tests`로 exact count를 고정하며 GREEN에서 범주를 합치거나 줄이지 않는다.
- **b2b focused-count 규율:** 각 구현 PR은 첫 RED commit에서 semantic/projection/seal 또는 recipe/compat 또는 owner/OOM test와
  proof-loss subprocess, boundary test의 exact inventory를 `--maru-expect-tests`로 고정한다. 같은 PR의 GREEN 단계에서 count를 줄이거나
  범주를 합쳐 통과시키지 않으며 Debug·ReleaseFast가 같은 semantic count를 실행한다.
- **b2b dependency boundary:** `process_seal_service`가 소유하는 cleanup input은 pointer-free neutral scalar/digest struct뿐이며 fixed-order
  little-endian encoder는 service-private다. service는 `RemoteRuntime|PendingEventOwner|Attachment|EventCorrelation` 구현, allocator, GUI/app type을 import하지 않는다.
  b2b가 canonical state를 neutral input으로 투영하며 boundary test가 import/caller inventory를 고정한다.
- **순서/증거 경계:** merge 순서는 `b2a -> b2b -> b3 -> b5 -> b4 -> b6`이다. b5는 dormant pending lifecycle 전수의 close readiness와
  real AppSession synchronous parity를 먼저 증명한다. `idle -> destroy`, `preparing|prepared|settling|committed_cleanup -> event_pending`,
  invalid raw tag -> fatal integrity를 전수하고 direct void deinit/detach 전용 source boundary를 고정한다. 실제 product `event_pending` close
  parity는 b4 activation 뒤에만 완료로 센다.
- **b5 RED inventory:** `test-session-host-2c3d-c3-3b5`는 Debug·ReleaseFast 각각 neutral contract 6개,
  lifecycle readiness 6개, close authority 8개, close sweep 8개, remote backend 8개, close graph 2개, AppSession parity 4개인
  unique component 42개와 boundary 1개를 실행한다. neutral 범주는 closed raw enum·VTable method-count 유지·pointer-free
  receipt·ticket 범위·progress shape를, readiness는 `idle|preparing|prepared|settling|committed_cleanup|invalid raw` 전수를,
  authority는 final-address/copy/replay/disposition/request generation/ticket/pin/callback/ready-remove를,
  sweep는 empty와 0/1/16/17/4,096 owner·frozen max·churn·stale replacement를 검증한다. backend 범주는
  multi-host 합산 cap/cap+1, 256 KiB scratch, iterator 종료 뒤 relookup, pin 뒤 다음 tick removal과 `closing_count` 비권위,
  두 host target의 연속 ticket reservation·copy/order splice 거부·routing 일괄 publication을,
  AppSession 범주는 in-process tab/window close·termination finish·invalid remove의 동기 수렴을 실제 제품 호출부에서 검증한다.
  b4 전 generation `event_pending` pump와 async close E2E는 component 수에 넣지 않는다.
  AppSession 네 행은 (1) in-process multi-Term close의 complete 뒤 topology commit, (2) mixed tab/window에서 remote pending이면
  sibling·active index·surface pointer·rename/paste는 byte-exact 보존하고 target routing만 exact once tombstone되며 이후
  input/control이 mutation 0인지, native `windowShouldClose`는 deferred로 창/teardown을 보류하고 모든 target removed 뒤
  programmatic close intent를 exact once 발행하는지, (3) termination finish의 complete→removed exact-once,
  (4) 현존 row의 stale remove는 layout을 보존하는 typed invalid이고 backend absence/replacement는 dedicated fatal leaf인지 각각 소유한다. window 주장은 pane-only fixture가 아니라 실제
  window-close intent/ABI를 통과한 non-last multi-window 행만 증거로 센다. 실행 중 명령 확인 전에는 graph mutation 0이고 confirm accept
  뒤에만 같은 close owner가 graph를 시작한다. 마지막 일반 창의 app-quit 경로는 b6 전에는 새 activation 0이다. authority 여덟 행은 final-address/copy, request generation replay,
  request-kind/disposition 표, ticket 경계, callback reentry, pin exact-once, ready-remove, closing receipt consume을 각각 고정한다.
  identity/state seal을 분리하고 pin이 exact PRE state generation과 허용된 POST만 인정하는지, active owner 중 same/cross-target
  callback close/remove/replace가 모두 `event_pending`·mutation 0인지 함께 검증한다.
  sweep 여덟 행은 empty+0을 한 행으로 묶고 1/16/17/4,096, frozen max, 무한 churn, stale replacement를 독립 실행한다.
  backend cap 행은 process-sealed singleton의 제품 `initAttachOnlyWithPool|initWithPool` exact claim, legacy `init` 제품 caller 0,
  init 실패 abort, deinit release·재생성, fork child 선거부와
  isolated fixture가 product singleton과 동시에 live일 수 없음을 포함하고 current/N-1 두 host의 committed+reserved
  합계가 4,096일 때까지만 허용한다. 4,097번째는 host RPC·allocator·map·routing·layout counter가 모두 0인 채 거부되고
  spawn과 attach/restore 실패 reservation은 각각 exact once abort된다. boundary는 `advanceClosePinned` 내부 semantic adapter caller 0,
  frame pump/close sweep의 direct settlement caller 0, direct void teardown exact allowlist와 일반 AppSession caller 0,
  VTable field count/name/order 불변을 함께 고정한다. ticket max 다음 발급과 invalid Pending raw는 서로 다른 전용
  fatal-integrity reason/subprocess origin을 사용한다.
  mixed tab/window 행은 `PendingTermCloseGraph`의 target별 preflight fault index `0..N-1`에서 reservation·backend authority·routing·topology가
  모두 pristine이고, 최초 성공의 callback/allocation/error/branch 0 no-fail publication에서 CloseAuthority와 target routing 전체가 함께
  tombstone되는지 검증한다. retry마다 app-session generation과 Term surface/handle의 현재 graph membership을 다시 증명하고
  Tab/Pane pointer를 identity로 사용하지 않는다.
- **b4 RED inventory:** `test-session-host-2c3d-c3-3b4`는 Debug·ReleaseFast 각각 중립 pump 계약 6개,
  Pending semantic commit 9개, 실제 Runtime event kind 9개, pump·round-robin 8개, async close parity 4개인
  unique component 36개와 fresh proof-loss subprocess 3개, boundary 1개를 실행한다. Pending 범주는
  `ignored|ended|invalidated|resize_noop|resize_commit|metadata_noop|metadata_commit|revoked|failure`를 각각
  `settling -> committed_cleanup -> idle`로 exact once 소비한다. Runtime 범주는 같은 아홉 tag를 실제 generation take와
  b3 settlement 뒤에만 semantic publish하며 fixture가 prepared union을 직접 주입하지 않는다. pump 범주는 idle,
  settlement Busy 뒤 같은 owner의 다음 tick 성공, 같은 tick busy-spin 0, purge-ended 우선, 16 owner 한 tick 진행,
  17번째 다음 tick 진행, checked `16 * 3 * protocol.max_control_json` frame budget, cursor/fairness를 독립 검증한다.
  async close 범주는 prepared와 committed-cleanup owner의 실제 backend `event_pending -> complete -> removed`, 실제 AppSession tab,
  native window-close 보류/one-shot 재개를 검증한다. subprocess는 metadata old-owner free callback 뒤 Pending seal drift,
  새 observation semantic seal drift, committed-cleanup continuation drift를 common proof-loss leaf의 exact exit로 구분한다.
  boundary는 `advanceClosePinned` 내부 `advancePendingEventForClose` exact 1, frame pump와 close sweep을 합친 settlement caller exact 1,
  b3 dormant raw release/apply generation arm caller 0, 아홉 tag와 product facade inventory, 테스트 전용 fault seam의 production surface 0을 고정한다.
- **b6 RED inventory:** `test-session-host-2c3d-c3-3b6`는 Debug·ReleaseFast 각각 shutdown 중립 계약 8개,
  attempt/outcome 권위 10개, 종료 manifest snapshot 2개, app-quit transaction owner 2개,
  current admin connector 3개, current-host admin 조정 9개, 이전 wire 회귀 profile/at-most-once 7개,
  진단 sink/bridge 8개, AppSession app-quit/graph-last teardown 8개인 unique component 57개와
  actual-socket product replay 4개, fresh proof-loss subprocess 3개, boundary 1개를 실행한다.
  actual replay는 current confirmed, current sent-ambiguous 뒤 barrier/inventory, 보존한 C3-3b5 base+patch universal 바이너리의
  sent-ambiguous at-most-once(배포 호환성 주장이 아닌 회귀 오라클),
  detach-preserve host EOF 뒤 fresh GUI reconnect를 각각 별도 socket/process에서 검증한다. subprocess는 receipt/seal drift,
  attempt generation overflow, lease generation overflow가 outcome·diagnostic·cleanup publication 없이 common fatal-integrity leaf로
  끝나는지 구분한다. boundary는 app-quit sole product caller, direct legacy terminate/detach allowlist,
  current CLI transport와 N-1 current-only connector 재사용 0, generation background blocking reader 0,
  neutral diagnostic DTO의 app/platform/logger import 0과 app-host bridge sole drain consumer를 고정한다.
  범주별 세부 행과 exact evidence matrix는 persistent-session-host의 C3-3b6 첫 RED 인벤토리를 단일 출처로 삼는다.
- **C3-3c 제품 socket/source-zero 인벤토리:** `test-session-host-2c3d-c3-3c`는 Debug·ReleaseFast 각각
  열린 peer의 revoked·unknown·semantic failure actual-socket component 3개, 봉인된 unknown의 ended 빠른 판별 회귀 1개,
  repo-wide raw event/effect source boundary 1개를 실행하고 C3-3b6 gate를 상속한다. 제품 행은 wire ingress 뒤
  Pending/EventOwner/correlation/mirror/event queue source-zero, blocker/pin/quarantine의 event 전 live attachment 기준선 복귀,
  payload callback exact 1회를 검증한다. RPC/decoder direct-call과 immediate EOF·unread RX-first는 2c3e가 소유한다.
- **2c3e C1 RED 인벤토리:** `test-session-host-2c3e-c1`은 Debug·ReleaseFast 각각 neutral contract 4개,
  scoped owner 8개, actual-socket replay 3개, fresh proof-loss subprocess 3개, boundary 1개를 실행한다. accepted
  response만 decoder callback exact 1회에 들어가고 reusable은 inline slot pristine rearm, protocol failure는 payload
  free 뒤 peer-contract terminal이 된다. typed reject·uncertain은 callback 0이며 callback reentry는 모든 generation
  mutation family에서 Busy다. copied/moved/alias와 callback 전후 seal/provenance drift는 mutation 0 또는 admission 뒤
  common proof-loss로 닫는다. boundary는 decoder callback 밖 raw slice·RPC owner/receipt escape 0, C1 bridge product
  caller 0과 raw wrapper baseline을 고정한다. C2의 exact 12 bound family 제품 전환과 C3의 immediate EOF·unread
  RX-first actual socket parity가 모두 green이 되기 전에는 2c3e 또는 2c3 완료로 표시하지 않는다.
- **2c3e C2 구현 인벤토리:** `test-session-host-2c3e-c2`는 C1 gate를 상속하고 Debug·ReleaseFast 각각
  실제 제품 RPC family 12개와 source boundary 1개를 실행한다. 열두 행은 `RemoteRuntime`의 resize, observation,
  selected text, link at, clipboard write, find, select op, core command, mouse report, notification, terminate,
  detach 공개 제품 흐름이 실제 socket 응답을 typed `RuntimeRequest`와 scoped decoder로 소비하는지 검증한다.
  boundary는 각 family constructor와 decoder 호출 exact 1, generation arm의 raw `callOrdered`·`Client.call` 0,
  queued input flush 선행, attachment-owned prepare/execute/abort와 C1 bridge 제품 caller exact 1을 고정한다.
  C3의 immediate EOF·unread revoke/event 우선 및 legacy/generation cadence parity가 green이 되기 전에는
  2c3e 또는 2c3 완료로 표시하지 않는다.
- **2c3e C3 cadence 인벤토리:** `test-session-host-2c3e-c3`은 C2 gate를 상속하고 Debug·ReleaseFast 각각
  legacy/generation을 같은 actual-socket oracle로 비교하는 cadence 12개를 실행한다. EOF는 immediate EOF와 완성 response 뒤 EOF를 같은 첫 행에서 고정하고,
  partial header 뒤 EOF, partial payload 뒤 EOF 세 행이다. response 전 RX는 revoke, metadata event, snapshot 세 행이고,
  response 뒤 RX도 같은 세 종류를 독립 실행한다. 나머지는 malformed frame, unknown kind 또는 wrong correlation,
  unread revoke와 queued TX의 RX-first다. 완성 response는 decoder exact 1과 다음 turn terminal을, 불완전 response와
  malformed/correlation failure는 decoder 0·response owner source-zero·connection terminal을 요구한다. revoke는 stale
  RPC publication을 막고, benign event/snapshot은 wire order와 exact-once 후속 소비를 보존한다. 12행 모두 실제
  socket의 legacy/generation 공통 oracle로 구현됐고 source boundary가 RX→settlement→TX와 decoder owner를 고정한다.

### 파일 탐색기 후속 두 PR gate (PR 1·PR 2 구현 완료)

- **PR 1 — open/root UX(구현 완료, ABI v137)**: `DockPanel.presented`와 `Tree.mode/roots/root_generation`, picker 없는 첫 open, 논리적으로 빈 tree만의 file picker, VS Code형 replace/add/remove, single-field workspace wire, mutation-busy/stale request 거부, 열린 dirty entry의 safety watcher 보존을 `zig build test`, C/Zig ABI 테스트와 Swift type-check로 검증한다. 제품 경로 headless 통합은 launcher→빈 dock, empty background picker, header/채워진 여백 no-op, header/root context menu, `FileTreeRootOutcome`의 cancel/invalid/busy/stale/commit reason, 2단계 identity 검증과 retained no-follow descriptor의 exact first-scan 이관, materialized row의 pinned root→parent no-follow 순회와 same-fd regular leaf identity, stale namespace row의 dock/external admission 0, symlink/non-regular fail-close, Markdown activation→initial hydration 사이 leaf 교체 read 거부, validation 중 live open/close 재투영, A→B→A scan fence, root-pending merge/restore 거부를 고정한다. workspace artifact는 유효 `0:`의 비표시와 malformed root field의 표시 의도 및 실제 terminal+entry 보존, 최대 64 group·127 node·256 entry·256 root에서도 512 field 미만, frozen legacy reader skip, raw/decoded/path/count cap, 전체 restore fail-index OOM rollback을 포함한다. tree artifact는 256 roots와 cap+1, row/watcher staging OOM에서 root/rows/watch/dock/tab 상태가 원자적으로 보존됨을 단언한다. HTML `loadFileURL`/외부 `NSWorkspace.open` admission 뒤 동일 UID pathname 교체는 공개 API 한계로 위협 경계 밖이며, 해당 race를 0이라고 주장하지 않는다.
- **PR 2 — scrollbar/icons(구현 완료)**: 중립 scrollbar geometry와 `IconKind` classifier를 boundary test에 등록했고 overflow-only thumb, top/bottom track/drag, fade, selection reveal, resize/root/projection generation 취소, NaN/∞ fail-close, 모든 좁은 폭의 cell 유일성을 자동 검증한다. 기본 Zig test는 외부 도구 없이 icon asset manifest/SHA-256, C/Zig registry, 모든 semantic codepoint의 coverage 등록과 generic fallback을 검증한다. `rsvg-convert`/Pillow가 필요한 SVG→coverage 재생성 drift는 프로젝트 의존성 정책에 따라 opt-in `mise run icons:check`가 맡는다. [성능 예산](performance-budget.md#파일-탐색기-scrollbaricon-예산)의 실제 AppSession 16,384-row/1,000-event counter fixture는 별도 macOS PR job의 전용 `mise run macos-file-explorer-perf`에서 `tests/artifacts/perf/file-explorer.txt`를 생성·업로드하고, Ubuntu의 `mise run perf`도 실행한다. 이 macOS job(`file explorer macOS product path`)은 branch protection required status다([필수 CI 체크](performance-budget.md#필수-ci-체크) 참조). artifact에는 실제 증가 지점이 있는 row/classifier/pointer/frame/geometry/quad/allocation/layout counter만 기록한다. 제품 macOS gate는 light/dark 및 focused/unfocused 단색 대비, 트랙패드/휠/drag와 divider/WebView 입력 무회귀를 확인한다.

| 영역 | 불가 이유 | 현재 한계 | 손해 | 예정 검증 경로 |
| --- | --- | --- | --- | --- |
| host-backed 선택 자동스크롤 | 구현 | `runtime_selection_state_v1`에서 controller의 selection start/extend/clear와 scroll+extend를 응답 없는 bounded FIFO로 host 권위 core에 미러링한다. 복사 전 flush와 host completion fence가 화면 밖 anchor를 보존한다. observer는 projection viewport 복사만 가능하고 host `all/authoritative/select_op`은 unauthorized다. | capability 없는 same-major host는 client/host viewport가 갈라지지 않도록 자동스크롤 transaction을 종전 no-op으로 낮춘다. | strict wire round-trip·malformed delta, closed generation projection, 실제 PTY의 start→두 번 scroll+extend→authoritative copy, controller/observer 인가 행렬, full `test-session-host`로 검증한다. |
| 모바일 어댑터(iOS·Android) | CI 미연결(사용자 결정)·실기기 없음·에뮬레이터 GPU 가 소프트웨어 래스터 | 로컬 하네스(`tools/mobile-harness/run.sh`)가 두 시뮬레이터에 설치·실행하고 `MARU_DRAW`(프레임당 draw call)·`MARU_PACE`(표시 간격 중앙값)·`MARU_ATLAS`(온디맨드 성장)·`MARU_INPUT`(입력 도달 누적 바이트)·`MARU_TOUCH`(셀 판정)·`MARU_LIFECYCLE`(창 파괴/재생성)을 로그 판정자로 남긴다. `atlas_diff.py` 는 두 기기가 구운 아틀라스의 픽셀 차이를 숫자와 그림으로 낸다. 브리지의 **코어 쪽 절반**은 OS 를 안 부르므로 `tests/mobile_bridge_contract.zig` 가 `zig build test` 에서 돈다 — 크기 변화·격자 경계·quad 용량·코어가 만든 답 배수·입력 누적 바이트·키 id 미러·커서 모양과 숨김이 여기 걸린다(**개수는 안 적는다** — 슬라이스마다 늘어 곧 낡는다). 스크롤 ABI(M4b1)가 붙으면서 **커서 가시성 규칙의 나머지 절반도 닫혔다** — 전에는 뷰포트를 올릴 수단이 없어 "스크롤백에서는 커서를 안 그린다" 는 테스트가 이름만 달고 있었고(`viewOffset() == 0` 을 지워도 통과하는 것을 변이로 확인했다), 지금은 실제로 스크롤한 상태에서 양쪽을 본다. 스크롤·선택·보조 키바가 붙으면서 판정자도 늘었다: `MARU_SCROLL`(Android 는 `finger_dy`·view_offset·선택 여부, iOS 는 뒤의 둘 — **손가락이 간 거리와 화면이 흐른 양을 나란히** 두는 것이 요점이다: 키바로 간 손짓은 앞이 크고 뒤가 그대로여야 하고, 그 둘이 같이 움직인 것이 R2 가 만든 관성 누출이었다)·`MARU_KEYBAR`(탭이 어느 키에 닿았나·눌러 둔 수정자)와, 코어에 **되묻는** 조회들(`maru_mobile_selection_span`·`maru_mobile_long_press_ms`) — host 가 자기가 보낸 값을 로그하는 것은 닿았다는 증명이 아니라서 넣었다. **그리기와 플랫폼 절반은** 손으로 돌려야 하고 `mise run check` 에도 CI 에도 없다. `features-ios` 는 `simctl spawn` 환경에서 멈춰 지금 못 돌린다(M8). **데모 바이트가 들고 있던 판정을 테스트로 옮겼다** — 터미널에 박아 둔 시험용 줄이 박스·블록·브라유·SGR 속성·양폭 한글을 화면에 뿌렸고 그것이 유일한 판정자였다(사람이 볼 때만). 그 줄을 없애며 계약 테스트가 대신 잰다: 합성 대상 코드포인트가 **커버리지** 아틀라스로 굽기 목록에 오르고(이모지와 반대 축), SGR 색이 팔레트 값 그대로 셀에 풀리며, 반전은 전경/배경을 맞바꾸고, 숨김은 글자를 **배경색으로** 만들고(quad 를 안 내는 것이 아니다 — 짐작이 반증됐다), 한글은 두 칸을 쓴다. **quad 로 재지 않는다**: 화면 quad 는 아틀라스에 셀이 있어야 나므로 굽기가 밀린 상태에서는 아무것도 안 세면서 초록이 된다(그 함정을 실제로 밟았다). **연결 진단(S9b-3b)도 기기에서 판정했다** — 닿을 수 없는 포트로는 "서버에 닿지 못했다 — 주소와 포트를 확인한다", `authorized_keys` 가 빈 서버로는 "키도 비밀번호도 안 먹었다" 가 두 기기 모두에 떴다(같은 실패가 **다른 말**이라야 사용자가 무엇을 고칠지 고른다). 그 회차가 결함 하나를 잡았다: **배너를 본문보다 먼저 그려** 셀 격자가 그 위를 덮었다 — 화면에는 아무것도 없었다. **그 배너가 두 번째 결함을 냈고, 그것은 기기에서만 보였다** — 컨트롤 채널(세션 목록)이 세션 준비 전에 지면서 남긴 이름이 펌프의 **한 슬롯을 두 축이 같이 쓰던 탓에** 터미널 배너로 실려 와, 셸이 멀쩡히 떠 있는데 "붙지 못했다" 가 세션 내내 떠 있었다(로그는 `state=11 error=not_running`). 같은 슬롯을 컨트롤 실패 로그도 찍어 **그 뒤 원인이 전부 첫 이름으로 보였다**. 축을 가른 뒤로 `tools/ssh/pump_smoke.zig` 가 "컨트롤이 져도 터미널 슬롯은 비어 있다" 를 재고 (그 전에는 같은 자리가 **혼선을 계약으로 고정**하고 있었다), 계약 테스트가 "READY 면 남은 이름이 있어도 침묵한다" 와 "채널을 못 열면 기다리지 않고 그 이유를 말한다" 를 잰다. **여기서도 못 재는 것이 있다**: 열기가 실제로 어느 시점에 서는지(host 가 `READY` 로 가르는 자리)는 소켓이 있는 쪽이라 기기에서만 보인다. **보조 키바의 armed 표시도 같은 부류였다** — `armed_mods` 는 내내 옳았고 그리는 자리만 틀려(`!= 0` 만 봤다) ctrl 을 켜면 alt 도 밝았다. 값을 재는 테스트로는 원리상 안 잡혀 `keybarArmedDrawn()` 을 그리기 경로에 세워 잰다. **IME 조합과 원격 전송이 어긋나던 자리도 기기에서만 보였다** — 소프트 키보드가 글자 하나에 `commitText` 와 `sendKeyEvent` 를 **둘 다** 부르는데 양쪽을 다 넘겨, 같은 글자가 두 번 원격으로 나갔다(`ㅈ` 한 번에 `ww`). 한글에서는 물리 배열이 QWERTY 라 `getUnicodeChar` 가 자모가 아니라 그 자리의 라틴 글자를 줘서, 조합 결과와 별개로 `rk` 가 나가 `zsh: command not found: rkr` 이 됐다. **로컬 화면에서는 안 드러난다** — `commitText` 만 반영하면 맞아 보이고, 원격이 나간 바이트를 에코하면서 비로소 보인다. 조합 표시도 같은 회차에 갈렸다: preedit 을 chrome 텍스트 경로 (`pushText`, 자기 스케일로 펜을 진행)로 그려 격자와 세로·간격이 어긋났고(M4a3 이 격자를 글리프 quad 로 옮길 때 안 따라온 자리다), 커서가 조합 폭을 안 세어 첫 글자를 덮고 앉았다. 계약 테스트가 "한글은 6바이트·2글자·**4칸**" 과 후보창 앵커 이동을 고정하지만, **IME 가 두 콜백을 다 부르는지는 여기서 못 잰다** **그 못 재는 자리가 곧바로 물렸다**(2026-08-23) — 중복을 막는 필터를 "유니코드 값이 0 이 아니면 글자" 로 적었는데, `getUnicodeChar` 는 **엔터에 `\n`·탭에 `\t`** 를 준다. 그 둘은 `commitText` 로 안 오고 키 이벤트로만 오므로 막는 순간 **대신 보내 줄 사람이 없어 통째로 사라졌다** — 원격 셸에 엔터가 안 먹었다. `MaruActivity.java` 는 host 층이라 Zig 계약 테스트가 못 보고 `doc_claims.sh` 는 grep 이라 로직을 못 본다: **기기에서 사람이 눌러야만** 드러나는 부류다. 판별을 "인쇄 가능한가" (`>= 0x20 && != 0x7F`)로 좁혔고, 그 기준은 브리지가 눌러 둔 수정자를 실을 때 쓰는 것과 같은 자리다. **그 자리가 한 번 더 물렸다**(2026-08-24) — 조합을 건너뛸지를 **수정자 유무**로 갈랐더니 `Ctrl+B` 는 나가고 **그 다음 키가 안 나갔다**. tmux prefix 다음 키에는 수정자가 없어 조합에 갇혔고, tmux 는 오지 않는 키를 기다렸다(기기 로그가 `02` 를 찍고 이어질 `6d` 를 안 찍었다 — 그 한 줄이 없었으면 "Ctrl+B 가 안 먹는다" 로 엉뚱한 곳을 팠다). 기준을 **문자 종류**로 옮겼다: ASCII 는 즉시 확정하고 조합은 한글에만 남긴다. **이 축도 기기에서만 보인다** — `MaruActivity.java` 는 host 층이라 Zig 계약 테스트가 못 보고, 어느 IME 가 무엇을 조합으로 넘기는지는 그 기기의 키보드가 정한다. **같은 회차가 레이아웃 결함 둘을 더 냈고 둘 다 기기에서만 보였다**: ① 소프트 키보드가 떠 있는 프레임에서 Android 가 하단 inset 을 **0 으로 보고**하는데(키보드가 navigation bar 를 덮으므로) 하필 그때 재조회가 걸리면 그 0 이 굳어, 키보드를 내려도 보조 키바가 **3버튼 위에 겹쳤다**(`bottom=135` → `bottom=0`). 0 은 값이 아니라 가림의 표시라 저장하지 않는다. ② 본문 격자가 레이아웃의 padding 을 제 몫으로 세어 **아래로 넘치고 그 넘침이 키바를 덮었다** — 계약(레이아웃 결과는 border box)이 이미 정한 것을 소비하는 쪽이 안 지킨 자리다. **끊는 자리(2026-08-24)는 계약 테스트가 잰다** — 뗀 것이 탭일 때만 요청이 서고, 밀면 안 서고, 한 번 가져가면 사라지는 것까지. 다만 그 요청이 실제로 소켓을 놓는지는 host 쪽이라 기기에서만 보인다. — 에뮬레이터에 한글 IME 가 없어 실기기가 유일한 판정자다. **처음 붙는 서버의 지문 승인(S9b-3)은 기기에서 판정했다** — 지문을 안 적은 config 로 붙어 화면에 뜬 지문이 `ssh-keygen -lf` 값과 **글자 하나까지 같은 것**을 보고, 승인하니 `state=11` 로 붙고 config 에 그 줄이 적혔다. 다시 켜면 **안 묻고** 바로 붙고, 서버 호스트키를 갈아 끼우면 `host_key_mismatch` 로 **묻지 않고** 끊는다. iOS 도 같은 화면에서 승인·거절이 모두 동작한다. **키 없이 붙는 길도 실서버가 잰다** — 열여섯째 회차가 키를 안 넘기고 `none` 으로 물어 같은 자리에 서는 것을 단언하고, iOS 시뮬레이터에서 **키 파일을 지운 채** 비밀번호 서버에 붙어 화면이 뜨고 sshd 가 `Failed password` 를 남기는 것을 봤다. **비밀번호 인증(S6a-2)은 반만 잰다** — 실서버 회차가 "비밀번호만 여는 sshd 에서 묻는 자리에 서고, 틀린 값은 되묻지 않고 실패로 끝난다" 를 단언하고, 기기에서는 두 기기 모두 화면에 친 값이 서버까지 가 sshd 가 `Failed password` 를 기록하는 것을 봤다. **맞는 비밀번호로 붙는 것은 못 잰다** — 진짜 계정 비밀번호가 필요한데 스모크가 그것을 알 수 없고 사람에게 물을 수도 없다(사용자 비밀번호는 쓰지 않는다). 그 성공 전이는 코어 단위 테스트가 `USERAUTH_SUCCESS` 를 먹여 채널 열기까지 확인한다. **공개키 보여 주기(S9c-4)도 기기에서 판정했다** — 두 기기에서 편집 화면의 그 줄을 눌러 `MARU_COPY len=85` 가 나오고 라벨이 "복사했다" 로 바뀌는 것을 봤다(Android 는 `id_ed25519.pub` 파일 길이와 그 85바이트가 일치하는 것으로 내용까지 대조했다). **붙여넣기 경로가 없어 앱 안에서 클립보드 내용을 되읽지는 못한다** — 그 축은 붙여넣기가 생길 때 닫힌다. **서버 목록·편집 화면(S9b-2b)도 기기에서 판정했다** — 두 기기에서 목록을 보고, 편집으로 들어가 포트를 고쳐 저장한 뒤(그 값이 config 파일에 실제로 쓰인 것을 읽었다) 그 서버에 붙어 `state=11` 까지 갔고, 삭제하면 목록과 파일에서 함께 사라지는 것을 봤다. 그 회차가 결함 둘을 잡았다: **숫자 키보드의 숫자가 네이티브 입력 큐로 와서 버려졌고**(포트 칸에 아무것도 못 쳤다), **긴 지문이 라벨 위에 겹쳐** 둘 다 못 읽었다. **접속 정보가 config 에서 온다(S9b-2a)도 기기에서 판정했다** — 두 기기에 일회용 sshd 의 서버 줄만 넣고(`ssh.server.1.*`, 기존 `ssh.conf` 는 지웠다) READY(state=11)까지 간 뒤 원격 셸에 친 글자가 돌아오는 것을 봤고, 세션을 끊고 배경에서 돌아오면 **다시 붙는 것**까지 확인했다(그 판단을 두 host 의 `onResume`·foreground 에서 브리지로 옮긴 회차라, 안 보면 재접속이 통째로 사라진 줄 모른다). **설정의 글자 칸(S9b-1)은 기기에서 픽셀로 판정했다** — 두 에뮬레이터/시뮬레이터에서 색 줄을 눌러 `#003300`·`#00ff00` 을 쳐 넣고 엔터로 확정한 뒤, 터미널 배경 픽셀이 정확히 `(0,51,0)`·`(0,255,0)` 이 되는 것과 config 파일에 그 줄이 쓰인 것을 함께 봤다. 그 회차가 결함 둘을 잡았다: 색 줄에 **숫자 패드**가 떠서 `#`·`a~f` 를 못 쳤고, 하드웨어 키 경로가 숫자 칸만 봐서 글자 칸에 친 글자가 **조용히 사라졌다**. | 회귀를 자동으로 못 막는다. **성능은 아예 못 잰다** — 에뮬레이터 GPU 가 `llvmpipe` 라 프레임 시간·배터리·발열 숫자에 의미가 없다. 실기기에서만 드러나는 것: 스왑체인 재생성(이 에뮬레이터는 리사이즈 뒤에도 `VK_SUCCESS` 를 돌려주고 SurfaceFlinger 가 낡은 버퍼를 늘린다), 한글 IME 조합→preedit 왕복(에뮬레이터에 한글 IME 가 없다), **iOS 가장자리 뒤로가기**는 여전히 사람이 밀어야 한다(한 번 닫았다고 적었다가 되돌린다 —
아래 재현 실패). `idb` 의 합성 터치가 `touchesBegan` 에는 닿는데 **제스처 인식기에는 안 닿는 것**은 사실이지만(가장자리 조건을 뺀 평범한 팬도 안 불렸다), **CGEvent 로 보낸 진짜 마우스 드래그**는 탭·스크롤까지는 확실히 닿는다(`sim_input.swift` — `MARU_TOUCH`·`MARU_SCROLL` 로 확인). **인식기는 한 번 걸린 뒤 재현이 안 됐다**: `MARU_NAV edge_back popped=1` 이 한 번 찍혔고 그 뒤 x=1~15·y=300~443 을 훑어도 어떤 상태에도 안 들어갔으며, **그 코드를 빼고 빌드해도 같았다**(A/B). 그러므로 "스크립트로 열렸다" 는 **탭·드래그까지**이고 인식기는 아니다. 덤: 앱 좌표 **x ≲ 4 의 터치는 시스템이 통째로 먹어** 앱에 로그가 안 남는다 — 모르면 코드가 죽은 것으로 오해한다. **iOS 여러 줄 선택 드래그**(`idb ui swipe` 는 **누르고 있다가 끄는** 제스처를 못 만든다 — 시작부터 균일하게 움직여서 길게 누름 문턱 전에 슬롭을 넘는다. **그 한계는 `idb` 의 것이지 CGEvent 의 것이 아니었다** — `sim_input.swift hold x y ms` 로 누르고 기다렸다 떼는 제스처를 만들어 **길게 눌러 단어를 잡는 것까지 스크립트로 쟀다**(2026-08-17: `MARU_SCROLL view_offset=78 sel=1` 뒤 2초간 바뀐 픽셀 0 — 관성이 선택을 미끄러뜨리던 결함의 판정자다). 남은 것은 **잡은 뒤 끌어서 여러 줄로 넓히는 것**이고, `hold` 뒤에 드래그를 이어 붙이면 되므로 그 경로를 쓸 때 닫는다. **다만 시뮬레이터가 합성 마우스를 통째로 안 받는 상태가 되는 일이 있다** — 앱 재설치 뒤 OS 홈 제스처까지 무반응이 됐고 재부팅으로도 안 돌아왔다(사람이 창을 한 번 클릭하면 풀린다). 홈 제스처를 보내 화면이 안 바뀌면 그 세션에서는 CGEvent 로 아무것도 검증할 수 없다 — 앱 결함으로 오해하지 말 것), **Android 하드웨어 키보드**(`adb shell input keyevent` 가 이 앱에 안 닿는다 — Java View 의 `onKeyDown` 도 NativeActivity 의 네이티브 입력 큐도 못 받았다. 검증 수단이 없어 배선을 넣지 않았다), 실제 vsync, **고주사율 패널**(에뮬레이터·시뮬레이터가 둘 다 60Hz 라 90/120/144Hz 에서만 나는 결함이 안 보인다 — Android 가 "vsync 한 번 걸러" 로 30Hz 를 만들던 것이 실제로는 **패널의 절반**이었고, 60Hz 에서만 우연히 30 이 나와 가려져 있었다. 경과 시간 기준으로 바꿔 닫았지만 **확인은 실기기에서만 된다**), **소프트 키보드가 뜬 상태의 레이아웃**(iOS 시뮬레이터는 기본으로 키보드를 숨기고 `defaults` 로는 안 켜진다 — `I/O ▸ Keyboard ▸ Toggle Software Keyboard` 를 `osascript` 로 눌러야 하고, 그건 **사람이 화면을 보는 경로**라 자동 판정자가 없다. 실기기의 키보드 높이·애니메이션·예측 줄 토글은 시뮬레이터와 다르다 — [UX §5.2](mobile-ux.md)). **두 host 대칭 대조에서 나온 것**(적대적 검증 9라운드): ① BMP 밖 글자가 두 플랫폼 다 빈칸이다(화면으로 확인 — [M4a6](plans/mobile-platform.md)), ② iOS 는 폰트에 없는 글자를 영구 공백으로 등록한다(Android 는 시스템 폴백이 붙는다), ③ Android `nativeKey` 는 표에 없는 키를 버려 **Ctrl+문자가 코어에 못 간다**(iOS 는 보낸다) — 지금은 그 경로로 이벤트가 오는 일 자체가 없어 잠복이고, 보조 키바(M4b)가 붙는 순간 드러난다. **키바를 다시 짜면서(U1) 이 한계가 드러났다** — 계약 테스트 전부가 통과하는 동안 화면은 깨져 있었다(눌림 표시 없음 · 임계 아래 손짓이 스크롤과 입력을 둘 다 냄 · 보이는데 안 눌리는 키 · 화면 끝에서 잘린 `>` · 창 폭이 키 배수가 아니라 남는 죽은 자리 · 늘 비어 있던 예약 48px · iOS 가 `CTLine` 으로 바뀌며 **온디맨드 글자가 전부 사라진 회귀**). **이 축의 판정자는 캡처와 손가락이고 테스트가 아니다** — 계약 테스트는 코어 쪽 답만 본다. **더 나쁜 쪽도 있다**: 계약이 바뀌자 `keyBarVisible` 이 늘 참인 술어로 남아 네 곳의 조건이 죽었고, `copy` 상시 표시를 지키던 테스트는 **고정 상수를 두 번 비교하는** 통과 보장 테스트가 됐다(둘 다 제거 — 커서 가시성 때와 같은 모양이다). **조건부로 나타나던 것을 상시로 바꾸면 그것을 지키던 판정도 같이 죽는지 본다.** | 실기기가 붙으면 회전으로 스왑체인 재생성을, 한글 키보드로 조합 왕복을, 성능 예산을 각각 확인한다([계획 M6](plans/mobile-platform.md)). `features-ios` 는 앱으로 바꿔 되살린다(M8). CI 편입은 러너 비용 때문에 지금 하지 않는다 — 필요해지면 그때 넣는다. |
| 실제 외부 오라클 실행 | Ghostty 다리·로컬 기본 `check`만 opt-in/환경 의존 | `mise run oracle-ext`(libvterm)와 `mise run oracle-alacritty`(Alacritty alacritty_terminal)는 CI `oracles` 잡이 매 푸시/PR에서 강제한다(golden == reference). `mise run oracle-ghostty`(Ghostty libghostty-vt)는 무거운 빌드 탓에 CI에서 제외돼 로컬 opt-in만이다. 셋 다 로컬 기본 `check`에는 미포함이고(각 reference 설치/빌드 필요), xterm 직접 실행은 비현실적이라 없다. | Ghostty 다리는 로컬 opt-in을 돌리지 않으면 golden이 검증되지 않는다. libvterm·Alacritty는 CI가 강제하지만 로컬 `check`만으로는 확인되지 않는다. | escape fixture가 늘면 세 reference로 golden을 생성/교차검증하고, Ghostty 다리의 CI 편입도 검토한다. |
| PTY/openpty controlled command | 환경 의존 | `mise run pty`가 macOS `openpty` backend로 controlled command, exit status, resize propagation, SurfaceRuntime routing, reader thread + bounded queue + RuntimeEventPump 경로를 검증한다. `mise run app-pty-smoke`는 같은 실제 PTY output이 app host renderer frame까지 들어가는지 opt-in으로 검증하고, `mise run app-pty-loop-smoke`는 실제 PTY reader thread event batch를 반복 `FrameLoop`로 frame화하며 idle frame까지 남긴다. `mise run macos-app-pty-metal-smoke`는 controlled PTY output과 AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key events roundtrip이 visible Metal glyph atlas sampling까지 도달하고, 같은 Metal terminal window의 AppKit close delegate callback이 `FrameLoop.closeActiveLivePty`를 호출해 registry에서 active surface live PTY를 찾아 mapping 제거, runtime detach, late output 거부, input 거부, queue close까지 수행하는지 검증한다. `mise run macos-app-pty-interactive-metal-smoke`는 같은 visible path에 실제 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 실행하고 marker command와 `exit`를 보내 shell startup/prompt/dotfile 영향을 받는 output도 Metal screenshot까지 도달하는지 검증한다. 기본은 synthetic `Cmd+B`이고 manual opt-in은 물리 `Cmd+B` 한 번을 같은 경로로 검증한다. 대량 stdout은 capacity 1 queue로 drop 없이 marker가 보존되는지 검증한다. reader close 경로는 signal을 무시하고 출력이 없는 child에서도 `stopAndJoin`이 blocking read를 정리하고 zombie를 남기지 않는지 검증한다. app/demo/smoke 코드는 `LivePtySession`으로 `PtySession`, queue, reader, runtime attach link의 live ownership을 공유하고, `closeAndDetach` 단위 테스트는 닫힌 surface의 routing을 먼저 끊는 close 계약을 검증한다. registry/host 단위 테스트는 `LivePtyRegistry`가 중복 surface/pty 등록을 거부하고 active surface mapping만 닫는다는 close command 계약을 검증한다. 아직 기본 `mise run check`에는 포함하지 않는다. | macOS가 아닌 환경이나 로컬 PTY 정책 문제는 기본 CI만으로 잡지 못한다. PTY backpressure의 RSS/latency/UI responsiveness 성능 예산은 아직 별도 검증 전이다. AppKit `keyDown:` input의 visible 경로, 물리 키 한 번을 받는 manual smoke, scripted visible interactive shell smoke, visible frame 뒤 같은 Metal terminal window AppKit close delegate callback은 생겼지만, macOS app event loop가 물리 키보드 입력을 지속적으로 받고 제품 tab/window close button을 `FrameLoop.closeActiveLivePty`에 연결하는 interactive lifecycle 검증은 아직 없다. `app-pty-smoke`와 `app-pty-loop-smoke`는 AppKit/Metal 창이 아니라 artifact 기반 headless app-host 결합 검증이다. | [PTY 운영 모델](pty-operating-model.md)에 따라 `tests/integration/pty/` artifact를 남긴다. 다음 단계에서는 app host가 input과 close lifecycle을 실제 window loop에서 호출하는 경로를 추가한다. |
| interactive shell smoke | 환경 의존 | `mise run pty`가 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL`을 `-i`로 띄우고 marker command를 입력해 `interactive-shell.raw.txt`, `interactive-shell.screen.txt`, `interactive-shell.snapshot.txt`, `interactive-shell.summary.txt`를 남긴다. `mise run app-pty-interactive-loop-smoke`는 같은 shell input을 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경계로 보내고 반복 frame artifact까지 남긴다. `mise run macos-app-pty-interactive-metal-smoke`는 같은 실제 shell을 visible AppKit/CAMetalLayer renderer path에 태우고 raw/screen/snapshot/screenshot artifact를 남긴다. 사용자 dotfile/prompt/locale에 따라 raw output과 screen artifact가 달라질 수 있고, 현재 VT parser가 ANSI 색상/cursor escape를 완전히 처리하지 못해 prompt escape가 screen artifact에 남을 수 있다. | 실제 login shell startup, prompt escape, dotfile 지연 문제를 조기에 볼 수 있다. app-level smoke는 shell input이 제품 loop가 쓸 keybinding 경계를 통과하는지도 보여주고, macOS visible smoke는 그 결과가 CoreText/Metal screenshot까지 도달하는지도 보여준다. 다만 여전히 scripted one-shot smoke이므로 shell과 사람이 계속 대화하는 제품 UX를 보장하지는 않는다. | `mise run pty`, `mise run app-pty-interactive-loop-smoke`, `mise run macos-app-pty-interactive-metal-smoke` opt-in smoke로 유지하고, VT parser와 제품 interactive app loop가 붙을 때 prompt/dotfile fixture를 더 분리한다. |
| 터미널 내부 workload (tmux/vim/htop/less/ssh) | 구현 전, 환경 의존 | 실제 TUI 프로그램을 Maru PTY 안에서 돌리는 workload smoke가 아직 없다. 이들은 정답을 계산하는 오라클이 아니라 파서를 압박하는 workload다. | alt screen, 복잡한 CSI, resize/SIGWINCH, mouse 처리 회귀를 실제 프로그램으로 잡지 못한다. | PTY와 runtime pump 경로 위에 opt-in smoke로 tmux/vim/htop 등을 실행해 crash 없이 snapshot까지 도달하는지 확인한다. |
| VT parser | 부분 구현 | core는 UTF-8 텍스트, CR/LF/Tab/BS, SGR(16/256/rgb 전경+배경, colon sub-param 포함), 커서 이동/위치(CUU/CUD/CUF/CUB/CUP/CHA/VPA), erase(EL/ED — ED 3은 스크롤백까지 클리어; ECH `CSI Ps X` — 커서부터 N칸 제자리 blank, 커서 유지), DSR/CPR(`CSI 6n`/`5n`)·DA1(`CSI c`→`CSI ?6c`) PTY write-back 응답, DECSC/DECRC(ESC 7/8 커서 저장/복원), scroll region(DECSTBM `CSI t;b r`)·IND/RI(ESC D/M)로 margin 안에서만 스크롤, alternate screen(DECSET 1049/47/1047/1048 — alt 출력은 스크롤백 비오염·뷰포트 잠금, 복귀 시 primary+커서 복원, alt 중 resize는 두 그리드 clip/pad), alternate scroll(DECSET 1007, 기본 on — alt screen에서 휠/트랙패드를 화살표 키로 변환해 less/vim이 자체 스크롤; 1줄 미만 트랙패드 델타는 누적), focus events(DECSET 1004 — 창 포커스 in/out을 CSI I(gained)/CSI O(lost)로 PTY 리포트; Swift window key/resign → ABI focus_changed → 활성 surface reportFocus, vim FocusGained/Lost), mouse reporting(DECSET 1000/1002/1003 트래킹 + 1006 SGR/1016 pixels/x10 인코딩 — 클릭/드래그/휠을 `CSI < Cb;Px;Py M/m`(SGR) 또는 `CSI M`(x10)으로 PTY 리포트; Swift `buttonNumber`→xterm 0/1/2·`modifierFlags`→mods 비트 변환, shift+click은 셀렉션 override, 휠=버튼 64/65, reportMouse 인코딩 unit 검증), synchronized output(DECSET 2026 — sync 중 metal frame 투영 hold, ESU에 누적 출력을 한 frame으로 그려 tearing/깜빡임 방지; DECRQM `?2026$p`로 지원 감지, render-skip과 동형; ESU가 영영 안 오면 sync timeout(1초를 host frame-loop tick으로 환산) 후 강제 투영해 freeze 방지 — Ghostty/xterm.js의 ESU-유실 안전 timeout과 같은 안전장치. 리더의 ESU 누적 카운트를 edge로 감지해(`shouldProjectFrame`의 esu_advanced) per-tick 폴링이 flush 창(<tick)을 놓쳐 완성 프레임을 막던 MISS도 없앤다 — Ghostty는 리더 ESU 이벤트로 렌더 트리거해 회피, maru는 tick 폴링이라 카운트 edge로 동형, MARU_DEBUG 계측 실측(연속 프레임서 막힘의 ~절반이 MISS였고 수정 후 0)), IL/DL(CSI L/M — region 한정 줄 삽입/삭제, history 비오염, 후처리 CR), 커서 표시(DECTCEM ?25 — snapshot cursor.visible에 합성), reverse(SGR 7/27 — Metal 투영이 전경/배경 스왑, default는 theme 색으로 풂), 이모지 grapheme: 국기(지역 표시자 RI 2개)는 한 셀(width 2)로 클러스터된다 — 두 RI를 한 셀로 묶어 emoji 폰트가 합쳐진 글리프를 그린다(unit 검증). RIS(ESC c)는 alternate_scroll(DEC 1007)을 공장 기본(켜짐)으로 복원한다. 변형 선택자(VS16 0xFE0F/VS15)는 0폭 combining으로 앞 글자에 붙어 base+VS16이 한 셀로 emoji 폰트에 가고(❤️ 컬러), default-emoji-presentation(✅⏰⭐ 등 0x1F300 미만 Emoji_Presentation=Yes)은 width 2로 잡아 slot이 잘리지 않는다(unit 검증). 컬러 글리프 판정은 단일 출처(width.isEmojiPresentation — 큐레이션된 default-emoji + 0x1F300~1FAFF + RI; 0x2600~0x27BF·0x2B00~0x2BFF 블록을 통째로 넣지 않아 ✓★♠ 등 단색 텍스트 기호가 컬러 경로로 새지 않음)이고, metal_frame은 VS16 결합(❤️)도 컬러로 본다. 래스터라이저는 그린 폰트가 컬러 테이블(sbix/COLR)을 가졌는지로 이모지를 판정해 단색 텍스트의 baseline을 지킨다. 커서 아래 컬러 이모지도 +2.0 sentinel을 유지해 색을 잃지 않는다. 이모지(컬러 글리프)는 슬롯을 꽉 채우도록 종횡비 유지하며 키우거나 줄여 가운데 맞춘다(Ghostty의 이모지 constraint .cover와 같은 의도 — CTM scale + ink-center; width 2면 2칸 풀사이즈, width 1이면 셀 폭에 맞춰 온전히). 일반 텍스트(한글/CJK 포함)는 축소-맞춤을 적용하지 않고 공통 baseline 정렬을 쓴다 — 축소+가운데정렬하면 baseline이 흔들려 윗/아랫줄과 어긋나기 때문(이게 회귀의 원인이었다). 큰 텍스트 글리프는 셀 메트릭으로 맞춘다. 컬러 이모지는 atlas의 RGBA를 그대로 렌더한다(셰이더 UV sentinel u>=2.0 — 일반 글리프는 coverage×전경색, 컬러 글리프는 atlas premultiplied RGBA를 셀 배경 위 합성; 래스터라이저가 emoji 폰트로 컬러를 atlas에 그린다, unit 검증). SGR 4(밑줄) 텍스트는 셀 하단에 전경색 밑줄로 렌더된다(draw_list의 UnderlineOverlay → metal_frame이 커서/hover 밑줄과 같은 부분-사각형 kind=2로 투영, unit 검증). 커서 모양(DECSCUSR `CSI Ps SP q` — block 반전/underline 하단 바/bar 좌측 바로 투영, blink는 app session이 host frame-loop cadence 기반 tick으로 500ms 반주기를 유지·입력/출력 시 리셋·steady는 고정, unit 검증), OSC 133(semantic prompt) 파싱·행별 정보 저장(A/B/C/D→prompt/input/command 행 분류 + `D;<code>` 종료코드를 행 단위 `RowPrompt{kind,exit}`로 묶어 `RenderSnapshot.prompt_marks`에 노출; lineFeed 전파·스크롤백 carry·RIS/ED2 리셋·alt screen 격리, glyph 쓰기로 리셋 안 됨; resize reflow·스크롤백 재-wrap도 분류+종료코드를 carry — unit 검증. zsh 통합이 마커 emit(PTY 캡처 검증). 프롬프트 점프 네비게이션(Cmd+↑/↓ → `core.jumpToPrompt`, `isPromptStart` 블록 경계로 뷰포트 이동; Swift는 keyCode 감지 후 `jump_prompt` ABI로 방향만 넘김 — unit 검증). 거터 ✓/✗(D가 프롬프트 시작 행에 종료코드 스탬프 → `draw_list`의 `GutterMark` overlay → `metal_frame`이 커서 bar kind=3을 col 0에 재사용해 초록/빨강 바, 그리드/PTY 폭 불변 — unit 검증)), OSC 7 cwd 보고(VTE 사실상 표준 `OSC 7 ; file://host/path` — host 무시·path만 percent-decode해 `TerminalCore.cwd`/ABI `..._cwd`로 노출, file 스킴만·malformed는 기존 cwd 유지·RIS에서만 리셋; zsh가 `nomultibyte` 바이트 단위로 percent-encode emit, `/a b/가`→`a%20b/%EA%B0%80` PTY 캡처 + 디코드 unit 검증), OSC 0/2 창 제목(xterm ctlseqs — OSC 0/2→`TerminalCore.title`, OSC 1 아이콘만 무시; `windowTitle`=제목>cwd basename>앱이름 우선순위를 Zig가 소유, ABI `..._window_title` → Swift `window.title`(비-`MARU_DEBUG`, 변할 때만 set), 빈 제목은 해제→cwd 폴백, RIS 리셋 — unit 검증, 시각 반영은 GUI 수동), APC(`ESC _ G ...payload... ESC \`)를 수집해 kitty graphics command(control `k=v`)를 파싱하고, transmit(`a=t/T`)이면 base64 payload를 디코드해 이미지를 저장하고(`KittyImageStorage` — RGBA `f=32`/RGB `f=24` 직접·zlib `o=z` inflate(`std.compress.flate`)·PNG `f=100` 8-bit truecolor 디코드(`png.zig` clean-room, 미지원 변종 graceful 거부)·chunked `m=1` 여러 APC 누적·크기 검증, 같은 id 교체·320MB 총량 한계·`a=d` delete·RIS 비움), display(`a=p/T`)는 현재 커서 셀에 placement로 걸어 `(image_id, placement_id)`로 저장(같은 키 교체·절대 행 anchor라 스크롤·eviction에 보정·화면 밖이면 제거·1024 상한·`C`/`r` 커서 이동 정책)하고 `RenderSnapshot.placements`로 노출하면, 렌더러가 셀 메트릭으로 placement→`GpuImage`(dest 사각형·source UV·z-pass) 환산(`buildGpuImages`)·generation 기반 텍스처 업로드 dedup(`planImageUploads`)을 거쳐 Swift/Metal이 image_id별 `MTLTexture`를 캐시해 textured quad로 그린다(K2 — 이미지당 개별 텍스처·premultiplied alpha·3-pass z를 maru 투명-셀 합성에 매핑: z<0은 셀 패스 전이라 텍스트 뒤로 비치고 z≥0은 후라 텍스트 앞; 코어는 셀 픽셀 크기를 몰라 환산·클립은 렌더러 몫, unit 검증; 화면 육안은 GUI 수동; transmit 디코드는 chunked `m=1`·zlib `o=z`·PNG `f=100`(8-bit truecolor) 지원, 풀 PNG는 라이브러리 백로그), OSC/나머지 private을 소비한다(unit+oracle 검증 — scroll region·alt screen·IL/DL은 libvterm·Alacritty 골든 일치). | DECOM(origin mode `CSI ?6h` — CUP/HVP/VPA가 scroll region 상대·region 안 clamp)·ICH/DCH(`CSI @`·`CSI P`)·BCE·ECH·focus events·mouse reporting·synchronized output·kitty keyboard CSI u 스택 dispatch[push `>`/pop `<`/set `=`/query `?`]가 모두 구현됐다. kitty graphics(APC)는 파서 + command + transmit 디코드(RGBA/RGB·zlib·PNG 8-bit truecolor·chunked, K3) + placement 코어 + GpuImage 환산·ABI·Metal 렌더(K2)까지 — 풀 PNG(라이브러리)·sixel은 별개 후속. **VT 호환성 갭 G1~G14도 전부 구현됐다**([터미널 입력과 VT 프로토콜 구현 이력](plans/terminal-input-and-protocols.md)의 "VT 호환성 갭") — SGR 확장(blink/conceal/double-underline/underline-color/strikethrough/overline/dim), OSC 색·클립보드·알림(10/11/4/104/52/9/777/110/111), DEC 라인드로잉 charset, 동적 탭스톱(CBT/HTS/TBC), REP, IRM, SU/SD, DECAWM off, DECSCNM, DECKPAM(numpad SS3), DECALN, BEL/NEL/VT/FF, 마우스 1015, DECRQSS+DCS 상태기계. 남은 것은 DECSTR·Sixel·kitty 애니메이션(레퍼런스도 미구현이라 보류). | 작은 ANSI fixture를 TDD로 늘리고 oracle snapshot을 함께 늘린다. |
| scrollback | 구현 | scroll-off된 행을 ring buffer(기본 1000줄)에 wrap 플래그와 함께 보관하고, view_offset 뷰포트 + scroll-lock으로 휠/Shift+PageUp 스크롤한다. renderSnapshot이 스크롤백+활성 화면을 현재 폭으로 합성한다(입력하면 바닥 복귀). **resize 시 스크롤백 행도 새 폭으로 재-wrap된다** — 보통은 지연 수행(resize는 마크만, 사용자가 과거를 보는 순간 1회; perf 게이트 scrollback_rewrap이 회당 비용 고정)하고, **과거를 보는 중이면 즉시 재-wrap하면서 보던 행을 앵커로 view_offset을 재계산해 스크롤 위치가 유지된다**(Ghostty tracked-pin과 같은 의미론 — 바닥으로 튕기지 않음). resize의 overflow push에도 scroll-lock 보정이 붙는다. 스크롤 변환은 Zig가 함(ABI v11). unit 검증(좁힘 분할/넓힘 합침/hard 경계 보존/cap 드랍/지연 트리거). | ring이 가득 차면 가장 오래된 행을 evict한다. 스크롤백→활성 경계에 걸친 논리 줄은 각자 재-wrap된다(경계에서 한 번 더 꺾일 수 있음). | 행 버퍼 풀링(재-wrap 1회 ~30ms를 더 줄이기)은 후속. |
| 선택/클립보드 | 구현 | 마우스 드래그로 셀 범위를 선택(절대 행 좌표 — 스크롤해도 내용을 따라가고, ring eviction 시 보정/해제)하고 Cmd+C로 추출 텍스트를 NSPasteboard에 복사한다. IME는 수정자 없는 타이핑을 `NSTextInputClient`로 처리하고, terminal 확정 UTF-8을 surface별 ordered input queue에 admission한다. Ctrl/Cmd는 물리 키코드 기준 레이아웃 독립 매칭(한글 모드 Ctrl+B→0x02 — ABI unit 검증, Dvorak 등 라틴 배열 보존)한다. preedit은 커서 위치의 **삽입형 미리보기**로 합성하고, 후행 run이 전부 faint면 인라인 자동완성 고스트로 보고 덮어쓴다(dim 고스트·비-dim 삽입·그리드 비오염·행끝 폴백·확정/취소 unit 검증). IME 판정은 Zig 키 트랜잭션이 일괄 수행하며 마지막 자모 Backspace 상쇄, 조합 조작 키 무전송, 확정 UTF-8 application admission 0-or-1회, `input.ime-enter` 설정에 따른 Enter의 atomic replay, 단일 C0 폐기, 포커스 아웃 확정을 검증한다. 자세한 host-backed 합성·OOM·전달 경계는 다음 `IME preedit snapshot 합성` 행과 [키 입력과 단축키 경계](key-input-and-shortcuts.md)가 단일 출처다. BS는 정확히 1칸이고, Cmd+V는 개행 정규화·DECSET 2004·ESC 치환을 적용한다. Cmd+클릭은 config 범위의 URL/파일 경로를 감지하고, OSC 8 링크를 우선하며, U+2026이 포함된 휴리스틱 토큰은 원본 복원이 불가능해 거부한다. 선택 추출은 soft-wrap을 잇고 hard 줄끝에 개행을 넣으며 wide continuation을 제외한다. **셀은 "글자가 없는 칸"(codepoint 0 — 터미널이 만든 빈 칸)과 "프로그램이 쓴 공백"을 구분한다**(`types.hasNoText`): soft-wrap 이음은 논리 줄 가운데라 **글자 없는 칸만** 잘라 잇고(`textLen` — 복사·검색), hard 줄끝은 쓴 공백까지 자른다(`textTrimmedLen`). 화면을 잃으면 안 되는 자리(스크롤백 저장·reflow)는 배경까지 보는 `paintedLen`을 쓴다 — 텍스트 경로가 배경을 보면 BCE로 칠한 화면에서 유령 공백이 되살아난다. 이 규칙이 없으면 2셀 글자가 밀리며 남은 칸이나 넓히는 resize의 패딩이 **없던 공백**으로 복사·검색에 섞이고, 재-wrap 때 진짜 셀로 구워진다(BCE 포함 다섯 경우 unit 검증). 같은 이유로 `DCH`/`ECH`가 **soft-wrap 행의 뒤쪽**을 비우면 그 자리는 이음에서 빠진다(글자가 없어 wrap 채움과 구분되지 않는다) — 행 **가운데**를 비운 자리는 뒤에 글자가 있어 공백으로 남는다(둘 다 unit 검증). 셀 변환·모델·추출은 Zig, 클립보드 쓰기만 Swift가 소유한다. | 선형(행 이어짐) 선택만 — 블록(사각) 선택 없음. 재-wrap/clear 시 선택 해제. 클릭(이동 없음)은 해제. 더블클릭=단어, 트리플클릭=논리 줄. | 블록 선택은 후속. 드래그 자동 스크롤은 경과 ms로 게이트해 frame rate와 무관하게 동작한다. |
| IME preedit snapshot 합성 | 구현(로컬·host-backed 공통, 실제 구 host binary/AppKit pixel gate 잔여) | `Surface`가 client-local `PreeditOverlay`를 소유하고 로컬 `TerminalCore` 또는 host-backed `RemoteScreen`의 base `RenderSnapshot`에 같은 합성기를 적용한다. canonical grid와 `size`·grapheme·prompt mark·command exit·placement·image·`ambiguous_wide`는 보존하고 cursor/dirty만 합성 결과로 바꾼다. 조합 폭은 base snapshot이 단일 출처다. 현재 host의 scrolled snapshot은 cursor를 숨기되 canonical live row/col을 보존하며, hello에서 `screen_viewport_scrolled_v1`을 협상했을 때만 `viewport_scrolled` mode bit를 신뢰한다. capability 없는 구 MRSH v2 host는 visible cursor가 해당 snapshot의 live bottom을 증명할 때만 preedit과 candidate anchor를 허용한다. hidden cursor는 scrollback과 DECTCEM-hidden live 화면이 모호하므로 둘 다 fail-closed하며, visible 증거는 snapshot마다 다시 계산해 latch하지 않는다. legacy host에는 `ambiguous_wide` mode bit도 없어 한글/CJK 고정 wide 폭은 표시하지만 ambiguous-width 설정 parity는 보장하지 않는다. host-backed `imeBegin`은 `async_scroll_to_bottom_v1`의 응답 없는 frame을 bounded outbound 슬롯에 nonblocking admission한다. `RemoteRuntime`의 64 KiB direct-key FIFO와 barrier offset이 cap 안의 후속 key를 소유해 `기존 input → scroll → 새 input` 순서를 보존하며, admission 뒤 frame encode OOM은 재시도하고 cap+1 admission은 효과 0으로 거부한다. blocking mouse/resize/observation RPC는 input/control FIFO를 먼저 flush한다. 구 host에는 동기 RPC로 fallback하지 않는다. 확정 UTF-8과 replay key는 같은 surface별 ordered queue에서 확정→replay 순서를 보존하고, cross-window workspace 이동 시 미전송 queue도 destination으로 이전한다. 이동은 source/destination terminal admission과 moved-queue transfer buffer/map allocation을 all-or-none 선예약해 어느 OOM에서도 composition commit/detach/model surgery 전에 중단하고 양쪽 구조·overlay·pin·queue를 보존한다. same-window는 active owner가 바뀔 때만 commit하며 merge는 destination active owner를 보존한다. 원격 nonblocking submit은 bounded preframed frame을 소유한 뒤 전송 구간에 `O_NONBLOCK`을 적용한 `MSG_DONTWAIT` write만 시도하고, EAGAIN/partial remainder는 frame-loop pump가 같은 offset부터 이어 보낸다. | marked text는 wire/runtime/workspace에 넣지 않는 attachment-local 상태라 observer·다른 창·detach/reconnect에는 공유되지 않는다. 대상 surface가 사라지면 tombstone pin을 유지해 다른 active terminal로 fallback하지 않는다. queue/누적 allocation OOM은 partial·replay-only·중복 admission 없이 0회로 fail-closed한다. exactly-once는 예약 성공 뒤 application admission/submit 범위이며 PTY 소비·원격 durable delivery ACK는 아니다. capability 없는 실제 구 host binary 재접속, pane/Term/tab 및 모든 비-terminal input owner 전환의 개별 제품 E2E, 실제 AppKit run-loop deadline과 후보창·한글 자모 중간 픽셀은 자동 검증하지 못한다. | unit/controlled 테스트는 local/remote 재합성, base ambiguous-width, current-host scrolled canonical cursor/mode, current-host hidden-live cursor, legacy visible-cursor 성공, legacy hidden-cursor 차단과 visible→hidden non-latch, clear·wide repair·dim ghost, OOM fail-closed, 중복 focus-loss, tombstone, ordered commit→replay, cross-window queue 이전, source/destination admission 각각의 abort-before-detach와 retry exactly-once, same-window active/background, merge destination owner 보존을 고정한다. socketpair backpressure는 direct-key ownership, exact-cap/cap+1, client encode OOM 재시도, request write hard-error 및 response-timeout connection invalidation, lifecycle fail-always OOM의 EOF fallback과 `input → scroll → input → mouse RPC`와 `input → core_command → input` frame 순서를, server test는 controller 적용·observer no-op을 검증한다. `zig build test`, `zig build test-session-host`, `zig build test-macos-app-host-abi`를 실행하고 실제 구 host·AppKit run-loop/pixel 경계는 수동 gate로 남긴다. |
| autowrap/reflow | 구현 | core가 deferred autowrap(DECAWM)을 구현하고, 행별 soft-wrap 플래그(wrapped)를 추적해 resize 시 활성 화면을 새 폭으로 reflow한다 — 논리 줄을 합쳐 다시 wrap하고 넘치는 위쪽 행은 스크롤백으로 민다. **커서가 있는 논리 줄은 reflow하지 않고 그대로 둔다**(xterm.js reflowCursorLine=false 방식 — 셸의 SIGWINCH 상대 redraw와 충돌해 프롬프트가 중복되는 것을 막고, 그 줄은 셸이 직접 다시 그린다). unit 테스트로 검증(커서 줄 verbatim / 비-커서 줄 reflow / 커서 clamp). | 이미 스크롤백에 있던 행은 다시 wrap하지 않는다. 커서 줄을 안 건드리므로 그 줄은 셸 redraw 전까지 옛 폭으로 clip돼 보인다. | 기존 스크롤백 행 재-wrap과 셸 통합(OSC 133 semantic_prompt)은 이후 단계. Ghostty 오라클은 Maru가 커서 줄 reflow를 생략해 분기하므로 skip(커서 없는 줄 검증으로 확장 시 재활성화). |
| wide-character(East-Asian width) | 자동 검증 중 | `Cell.width`, `Cell.continuation`, `Cell.grapheme_id`/`TerminalCore.grapheme_store`로 한글/CJK/emoji 2-cell과 combining 0-cell을 검증한다. combining mark·NFD conjoining 자모는 직전 cell cluster에 0폭으로 흡수되고 base가 없으면 drop한다. macOS NFD 한글은 한 음절 셀(폭 2)로 묶여 dump/복사/snapshot에서 무손실 복원되며 CoreText에서 완성형과 같은 glyph로 합성된다. 다중 combining·키캡도 store에 누적한다. mode 2027에서는 ZWJ 가족·RI 국기·skin-tone을 단일 emoji cluster(폭 2)로 묶는다. `text.ambiguous-width = narrow|wide` 설정은 loader/reload/core에 구현되어 있고, base `RenderSnapshot.ambiguous_wide`와 current host screen mode bit가 renderer/preedit 폭의 단일 출처다. | 완전한 UAX#11/Extended_Pictographic 속성표(현재 흔한 블록 큐레이션), mode 2027이 꺼진 환경의 ZWJ 폭 정책, box-drawing 정렬은 아직 전부 보장하지 않는다. legacy host에는 `ambiguous_wide` bit가 없어 degraded preedit의 ambiguous-width parity를 보장하지 않는다. 픽셀 PNG 캡처는 폰트 의존이라 visible 앱 수동이다. | NFD 한글·ZWJ 가족·skin-tone·마지막 열 combining·no-base drop·wide backspace·ambiguous narrow/wide와 current host-backed preedit parity를 unit/recorded oracle/CoreText smoke로 검증한다. legacy host는 한글/CJK 고정 wide preedit만 보장한다. Unicode table 확장 때 fixture를 추가한다. |
| PTY 경계 분할 UTF-8 | 자동 검증 중 | `TerminalCore`가 incomplete UTF-8 tail buffer를 보존한다. 아직 invalid UTF-8 복구 정책은 별도 설계 전이다. | malformed byte stream 처리 정책은 아직 제품 UX로 확정되지 않았다. | unit test, split UTF-8 recorded oracle fixture, split chunk stress가 기본 `mise run check`에 포함된다. invalid UTF-8 정책을 정할 때 별도 fixture를 추가한다. |
| modifier/application-cursor 키 인코딩 | 구현 | `encodeKey`는 `Ctrl+letter` C0 control과 `Alt/Option` meta-ESC를 처리하고, DECCKM(`CSI ?1h/l`)에 따라 화살표를 SS3(`\x1bOA`)/CSI(`\x1b[A`)로 전환한다 — TerminalCore가 모드를 추적하고 app host `handleKeyEvent`가 매 키마다 active core의 `EncodeOptions`를 읽어 넘긴다(unit + host E2E 검증). host-backed 일반 key는 attachment placeholder(빈 core)가 아니라 runtime observation(`app_cursor_keys`·`app_keypad`·`kitty_flags`) override(`AppSession.hostBackedEncodeOptions`→`encode_options_override`)로 host가 켠 DECCKM/DECKPAM/kitty mode대로 인코딩한다(P3-e4c-4; 구 host는 관측에 필드가 없어 numeric·legacy 기본값 폴백). `KeyBindingResolver`는 app action과 terminal input macro를 분리한다. | 기능키(Home/End/Insert/Delete/PageUp/PageDown/F1~F12) xterm legacy 인코딩·바인딩은 구현됐다(터미널측, Linux CI). AppKit ABI/Swift 매핑으로 물리 키도 연결됨(계약 테스트). kitty keyboard protocol(opt-in)은 구현됐다 — 앱이 `CSI > flags u`로 켜면 flag 스택(push `>`/pop `<`/set `=`/query `?`)을 따라 encodeKey가 disambiguate 인코딩으로 분기해 escape·Ctrl+key·화살표/기능키 modifier(`CSI 1;2A`·`CSI 97;5u` 등)를 CSI u 시퀀스로 보낸다(미활성이면 legacy 그대로 — progressive enhancement, unit 검증). legacy 경로의 modifier 조합도 구현됐다 — 커서/편집/기능키가 `CSI 1;{mod}<letter>`·`CSI {n};{mod}~`로 나가고 `Shift+Tab`은 `CSI Z`다. **kitty 경로와 같은 헬퍼(`encodeKittySeq`·`kittyModsSeqInt`)를 써서 두 경로가 갈릴 자리가 없다.** report_events/alternates/associated(release·대체키·연관텍스트)와 F13~F24, legacy `modifyOtherKeys`는 아직 없어 긴 꼬리 호환성은 일부 부족하다. | 다음 입력 확장(report_events/alternates)에서 같은 EncodeOptions 경로에 fixture와 단위 테스트를 추가한다. |
| GPU renderer | 부분 구현, 환경 의존, 시스템 한계에 가까움 | backend-neutral `DrawList`, `ShapedGlyphRecord`, `GlyphRunList`, `GlyphFrame`, `GlyphQuadFrame`, `GlyphRasterFrame`, persistent `RendererState` 계약은 있고, cursor-only 이동 dirty와 cursor/underline overlay command도 자동 검증한다. app host smoke가 `GlyphRasterFrame`까지 포함한 `RenderFrame`을 조립하고 `app-host.glyph-frame.txt`를 남기며, live PTY app host smoke가 실제 PTY output을 같은 app host renderer frame으로 바꿔 `app-pty.frame.txt`를 남긴다. macOS window smoke는 실제 AppKit 창을 띄운다. macOS Metal smoke는 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> RenderFrame -> coretext_raster.zig`가 만든 `GlyphQuadFrame/GlyphRasterFrame` cell quad를 present하고 source raster non-clear 위치를 readback하며, native cell이 atlas slot id와 `x_px/y_px/width_px/height_px` placement 후보를 받았는지 `renderer_atlas_slot_placement=true`로, shader UV 변환이 준비됐는지 `renderer_glyph_uv_ready=true`로, upload byte/skip 회계가 끝났는지 `renderer_glyph_raster_ready=true`와 raster skip count로 남긴다. 같은 smoke에서 제품 `GlyphRasterFrame.uploads/pixels`가 Metal atlas texture에 업로드되고 readback byte 비교까지 통과하면 `product_atlas_uploaded=true`, fragment shader가 같은 atlas를 샘플링해 drawable readback이 source texel과 일치하고 sample source 누락이 없으면 `product_atlas_sampled=true`와 `glyph_text=true`가 되며, 같은 drawable을 `metal-frame.ppm`으로 남기면 `screenshot_artifact=true`가 된다. macOS CoreText smoke는 GPU 없이 font stack, drawable font identity의 `FontIdentityRegistry -> coretext_shaper.zig -> GlyphRunList -> RendererState -> RenderFrame -> coretext_raster.zig` 준비, 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> GlyphRunList -> RendererState -> RenderFrame -> coretext_raster.zig` 준비, smoke native bridge가 만든 CoreText `GlyphRasterFrame` bytes, CPU glyph rasterization을 분리 검증하고, `font_identity_ready=true`, `renderer_shaper=coretext_shaped_records`, `drawlist_renderer_shaper=coretext_draw_list`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_frame_prepared=true`, `drawlist_frame_prepared=true`, `renderer_glyph_raster_ready=true`, `drawlist_glyph_raster_ready=true`를 남긴다. macOS glyph texture smoke는 CPU glyph bitmap이 Metal texture로 보존 업로드되는지 확인한다. macOS glyph text smoke는 그 texture를 실제 AppKit/CAMetalLayer 창에서 shader sampling하고 drawable readback과 PPM screenshot artifact로 glyph ink를 확인한다. 즉 `RendererState -> RenderFrame/GlyphQuadFrame/GlyphRasterFrame` 제품 frame 준비, 실제 PTY output -> app host renderer frame, `TerminalCore -> DrawList -> CoreTextDrawListShaper -> GlyphRunList -> RendererState -> RenderFrame -> GlyphQuadFrame/GlyphRasterFrame -> Metal atlas upload/readback/shader sampling -> screenshot artifact` 소비 경로, controlled PTY output + AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key events roundtrip -> visible Metal atlas sampling -> screenshot artifact 경로, scripted interactive shell -> visible Metal screenshot 경로, `CoreText -> CPU bitmap -> Metal texture -> shader sampling -> drawable readback -> screenshot artifact` 경계는 생겼지만, 아직 사용자가 계속 입력하는 제품 interactive shell app loop는 아니다. macOS CoreText smoke와 Metal smoke는 CoreText shaper/rasterizer wrapper와 native raster bytes를 쓰지만, native raster implementation은 아직 smoke bridge에 있다. glyph text smoke의 renderer probe만 아직 `renderer_shaper=fake_font_backend`로 기록되는 fake shaper 경로다. 실제 화면 검증은 macOS window server, GPU driver, font stack 영향을 받는다. | frame pacing, 실제 cursor blink/selection 렌더링 문제를 검증하지 못한다. selection dirty는 아직 selection domain data가 없어 검증하지 않는다. static Metal smoke는 실제 `TerminalCore -> DrawList` fixture를 화면에 그리고, live PTY Metal smoke는 controlled PTY output과 AppKit `keyDown:`에서 app host keybinding resolver scripted key events roundtrip 및 scripted interactive shell marker를 화면 present까지 연결한다. manual mode는 물리 키 한 번을 받지만, 아직 없는 것은 지속 interactive shell lifecycle이다. screenshot artifact는 사람이 방향/배치를 확인하게 하지만, 자동 OCR이나 pixel-perfect glyph orientation 판정은 아직 하지 않는다. glyph text smoke는 단일 CoreText fixture texture를 그리므로 cell-grid text layout과 atlas packing을 증명하지 못하고, renderer probe도 실제 CoreText shaper를 쓰지 않는다. | [렌더러 전략](renderer-strategy.md)에 따라 실제 PTY/shell input을 AppKit/Metal app loop에 연결한다. selection overlay는 selection 모델 도입 PR에서 별도 검증한다. |
| font/layout/glyph atlas | 부분 구현, 환경 의존 | fake backend 기반 `DrawList -> GlyphRunList -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` 계약, native shaper 결과를 renderer 중립 `ShapedGlyphRecord -> GlyphRunList`로 바꾸는 adapter 계약, macOS `coretext_font.zig`가 native drawable font face를 안정적인 renderer `FontId`로 바꾸는 `FontIdentityRegistry` 계약, macOS `coretext_shaper.zig`가 CoreText glyph record 배열과 explicit `ShapedGlyphSurface`를 제품 `GlyphRunList`로 바꾸며 surface metadata를 보존하는 계약, macOS `coretext_raster.zig`가 FontId -> PostScript name 조회와 native bridge 호출 실패 매핑을 소유하는 계약, GPU 없는 `GlyphCacheKey -> AtlasSlot` cache/placement/grow 계약, macOS CoreText font resolve/glyph run/`RendererState -> RenderFrame -> coretext_raster.zig` 준비/native CoreText `GlyphRasterFrame` bytes/CPU raster smoke, CoreText bitmap -> Metal texture upload smoke, glyph texture shader sampling smoke, 제품 `GlyphRasterFrame.uploads/pixels` -> Metal atlas texture upload/readback/shader sampling smoke가 있다. `AtlasSlot`은 backend UV 계산을 위한 deterministic `x_px/y_px` 좌표 후보를 가지고, `GlyphQuadFrame`은 이를 normalized UV로 바꾸며, `GlyphRasterFrame`은 fake rasterizer 또는 `coretext_raster.zig` wrapper로 upload 후보를 contiguous RGBA bytes 또는 명시적 skip으로 바꾼다. Metal smoke는 실제 `TerminalCore -> DrawList` fixture를 CoreText runtime으로 shape하고, CoreText wrapper로 만든 제품 raster bytes를 Metal atlas texture에 올려 shader sampling과 screenshot artifact까지 확인한다. growable atlas와 통합 멀티 페인 빌드는 단위로 검증되지만, device-scale별 eviction/upload 성능 예산과 split 동시 멀티 surface + 강제 grow의 실제 GPU readback smoke는 아직 없다. | 실제 fallback cache 성능, Retina glyph 선명도, font 설정 오류, split 동시 멀티 surface texture packing 회귀를 자동 검증하지 못한다. glyph id와 atlas key 후보, font identity registry 계약, `RenderFrame` 준비, slot 좌표 후보, UV 변환, fake upload bytes/skip, CoreText raster bytes, CPU bitmap, Metal texture 보존, shader sampling, 제품 raster bytes의 Metal atlas texture 보존과 CoreText atlas sampling은 확인한다. Metal smoke는 실제 `TerminalCore -> DrawList` fixture가 cell-grid text로 보이는지도 확인하고 PPM screenshot artifact를 남기며, live PTY Metal smoke는 controlled PTY output, AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key events roundtrip, scripted interactive shell marker output도 같은 path로 확인한다. manual mode는 물리 키 한 번을 받지만 지속 interactive shell은 아직 없다. | [폰트 전략](font-strategy.md)에 따라 `FontIdentityRegistry`가 만든 같은 `FontId`를 shaping과 rasterizer 조회에 함께 쓰며, device-scale별 atlas packing/eviction 성능 metric과 split 멀티 surface GPU readback smoke를 추가한다. |
| 멀티 페인 cross-pane atlas 통합 | 시스템 한계에 가까움 | 멀티 페인이 한 atlas를 공유할 때 뒤 페인의 `invalidate`/grow가 앞 페인 슬롯을 무효화하는데 업로드는 페인별 miss만 해(앞 페인은 hit이라 누락) 빈자리/덮인 좌표를 샘플하던 cross-pane 깨짐(분할+탭 빠른 전환 시 폰트 폴백 글리프가 다른 글자/빈 칸으로)을 **통합 빌드**(모든 페인을 한 `placeMultiPane` 세대로 — 소진 시 전체 재시작해 전부 miss→전부 uploads, 활성 panel `shapeOnlyBuild`까지 합류)로 근본 수정했다. **직접 원인은 단위로 자동 증명**: `prepareMultiPaneGlyphFrame`(distinct/공유 글리프 hit 경로/빈 페인 — 한 세대 재시작·전부 uploads) + `placeAndDistribute`(dest 분배·collected 소진·소유권, macOS 게이트·의도적 fail로 실행 확인). 단일 surface GPU smoke(`mise run macos-app-pty-metal-smoke`)가 활성+chrome 통합 atlas를 `atlas_readback_mismatched_bytes=0`·`atlas_sample_missing_cells=0`로 검증한다. | **split 동시 멀티 surface**(비활성 pane 추가) + **atlas 소진(grow/invalidate) 강제**의 실제 GPU 텍셀 덮어쓰기는 단일 surface smoke 밖이다(fake rasterizer는 0xff라 못 봄). 즉 split+탭 전환의 텍셀 cross-pane 회귀를 자동으로 못 잡는다(직접 원인은 단위·단일 surface로 커버). | **수동**: 앱에서 ⌘D로 분할 → 각 pane에 CJK/이모지(폰트 폴백 유발) 입력 → 탭을 빠르게 전환하며 글리프가 다른 글자/빈 칸으로 깨지지 않는지 확인. **자동 GPU split smoke는 좌표 회수/atlas packer 착수 PR의 첫 단계(red→green)로 만든다**([font-strategy.md](font-strategy.md) 좌표 회수 항목) — atlas readback byte 비교라 OS 폰트 무관(flaky 아님). 지금 독립 제작은 지킬 회귀(좌표 회수)가 보류라 YAGNI. |
| workspace/surface restore | 구현 (멀티 창 저장·복원 + cross-window 이동 재시작 유지 + 활성 창 focus — M3e + 창 geometry 복원 — M3f) | `saveWorkspace`/`restoreWorkspace`(`MaruAppHost.swift`)는 멀티 창을 창별 per-session `Model` 블록(`maru.workspace.v1`)으로 저장·복원한다(첫 블록 primary + 나머지 블록마다 새 창 — [window-surface-mobility.md](window-surface-mobility.md) §7). cross-window 이동(M3d) 결과는 각 세션 라이브 트리를 창별로 저장하므로 **이미 재시작 후 유지**된다. **M3e(사용자 리뷰)**: 저장 권위를 `WindowGraph` v2 문서로 옮기는 전환은 **과설계라 기각**했다 — 이동 배치는 이미 유지되고, 유일한 델타인 **활성(key) 창 focus만** `maru.workspace.v1`에 옵션 additive 필드 `active-window`로 더했다(헤더 bump·window_id/window_kind 없음·완전 하위호환, §8A.6). **M3f**: 같은 옵션 additive 패턴으로 **창 geometry(위치·크기·모니터)** 복원을 더했다 — `Window.frame`(전역 스크린 좌표 점) → window 라인 옵션 필드 `win-x/y/w/h`(all-or-none·null=생략), ABI `serialize_workspace(…, has_frame, frame_x/y/w/h)` + 창별 getter `workspace_window_frame`, Swift `saveWorkspace`가 `window.frame` 저장·복원 시 `clampFrameToVisibleScreens`(모니터 분리 방어)→`setFrame`. 전역 좌표가 모니터를 자동 인코딩하므로 display ID 불필요. 헤더 유지·완전 하위호환(옛 파일·M3e-only 파일 win-* 없이 cascade). round-trip(음수)·생략 고정점·하위호환·부분 필드·값 손상 테스트(`workspace.zig`). | cwd/env/command/layout restore가 실제 사용자 UX로 보장되지 않는다(E2E 미비). 창 geometry의 실제 멀티모니터 `setFrame`·clamp는 GUI 손 테스트(스크린샷 하니스 밖). | [Workspace Restore 전략](workspace-restore.md)에 따라 serialized workspace fixture와 restore E2E를 추가한다. |
| 파일 패널 FP1+FP3 도크 모델·영속·라이브 슬롯 | 구현(FP1+FP3, headless+macOS) | FP1의 `DockPanel`/workspace.v1 계약에 FP3 `dock_layout.zig`의 right/bottom 기하·terminal floor를 연결했다. `AppSession` 소유·capture/apply, termRect+gridPadding, 전 탭 PTY resize, ChromeProps workspace rect, GPU 탭/경로 밴드, 접기/리사이즈/탭 hit-test를 한 기하에서 파생한다. 도크 WKWebView는 기존 surfaceDiff batch에 합류하고, `web_surfaces_present`·`hasWebSurface`·workspace right/bottom dock-edge seam·dock group/tree seam·drag 중 visibility 유지+live reframe을 통합 테스트한다. 확장 grab band의 divider↔pointer offset을 세션 동안 보존해 첫 drag 무점프와 delta 정합을 고정한다. 도크 밖 mouse-down은 workspace로 fall through하며, 열린 도크와 browser 주소창의 편집·문자 입력 회귀 테스트가 이를 고정한다. | FP6가 별도 도크 포커스/IME 축을 연결했다. `MARU_SCREENSHOT`은 Metal 레이어만 readback하므로 WebKit 픽셀은 실제 DOM 상태 probe로 검증한다. | `mise run test`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run check`, right/bottom 제품 스크린샷. |
| 파일 패널 FP2 web 툴체인·sanitizer | 구현(FP2, Bun/headless) | `web/`가 exact lock, zntc Safari 16 ESM, SHA-384 SRI, Oxc, remark/unified sanitizer와 전체 lock graph license allowlist를 소유한다. FP4 build는 production dependency graph만 추적한 `THIRD_PARTY_NOTICES.txt`를 생성하며 dev tool 제외·전문 누락 fail-closed를 테스트한다. | Mermaid는 FP4 격리 origin/CSP 이후에도 출력 sanitize 전 요청 0이 별도 증명될 때까지 inert다. | `bun install --cwd web --frozen-lockfile` + `mise run web:check`. |
| 파일 패널 FP4 read bridge·격리 viewer | 구현(FP4, Zig+Bun+실 WKWebView) | L2 `file_panel_bridge.zig`가 상대 asset 경로/MIME를, `control_bridge.zig`가 strict params·UTF-8/base64 응답을 소유한다. `AppSession`은 markdown surface에 핀된 파일과 descriptor-relative/no-follow asset을 nonblocking fd로 열고 같은 fd의 stat/read에서 정규 파일만, 정확히 8 MiB까지 허용한다(FIFO 회귀 테스트 포함). shell은 64 asset/48 MiB base64 aggregate를 제한한다. `appOriginAllowed`가 scheme+host+명시 port 부재를 shell/render/asset 역할별로 고정한다. `maru-app://app` shell이 sandboxed `maru-app://render` iframe을 구동하며 CSP는 그 exact frame origin만 허용한다. 신뢰 Markdown WebView는 macOS 12+에서 생성 시 semantic under-page 배경을 설정하고 두 HTML의 동일 critical `Canvas` style은 외부 CSS보다 앞서며 CSP가 그 SHA-256 하나만 허용한다. Bun tests와 macOS smoke가 fixture 본문+SVG 1/1, renderer bridge/message-handler `undefined`, 부모 DOM 접근 `false`, critical-style/hash 정합과 실제 WebKit stylesheet 채택, native under-page 설정을 검증한다. | FP6 write/CM6도 같은 trusted-shell/bridge-free-render 경계를 재사용한다. renderer `allow-same-origin`은 app/render host 분리와 runtime parent-access gate가 함께 있을 때만 안전하다. Metal screenshot은 WKWebView 픽셀을 담지 않으므로 실제 첫 paint 무백색 여부는 light/dark GUI 손 테스트가 최종 시각 gate다. macOS 11은 공개 under-page API가 없어 pre-document backing이 남으며 current-host smoke로 11 분기를 증명하지 않는다. | `mise run web:check`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-app-smoke`, `mise run test`, `mise run check`, `mise run macos-browser-bounded-smoke`. |
| 파일 패널 FP5 열기 라우팅·HTML 격리 | 구현(FP5, Zig+AppKit+실 WKWebView) | ABI v121이 `open_file_panel` one-shot과 절대경로 open, surface→도크 entry 조회를 제공한다. 기본 `⌘O`·메뉴·팔릿과 터미널 `.md`/`.html` 링크가 같은 Zig 확장자/regular-file/중복 활성화 정책을 쓰며 workspace 복원도 절대 UTF-8·kind↔확장자·regular-file을 재검증해 잘못된 entry만 제거한다. HTML은 부모 디렉터리 read scope의 `loadFileURL`, browser와 별도인 도크 전용 ephemeral store, 핀 파일 top-level 정책을 쓴다. 직접 활성화한 http(s) 링크만 외부 브라우저, 다른 이동은 취소한다. macOS smoke가 script·내부 SVG·scope 밖 차단·형제 링크와 programmatic `about:blank` 뒤 pin을 검증한다. | FP6가 도크 키보드 focus/IME와 merge 이관을 연결했다. 파일 링크가 아니라 명시 `file:` 스킴을 주소창에 넣는 경로는 계속 거부한다. | `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-app-smoke`, `mise run web:check`, `mise run test`, `mise run check`, `mise run macos-browser-bounded-smoke`. |
| 파일 패널 FP6 CM6 편집·write·dirty/focus/merge/LRU | 구현(FP6, Zig+Bun+AppKit+실 WKWebView) | ABI v122가 surface-pinned pathless `file.write/setDirty`와 mode getter/take를 제공한다. CM6 Markdown source editor는 bridge-free render iframe과 분리된 trusted shell에서만 raw text를 다루며 Cmd+S 저장과 앱-bound 편집 키 양보를 구현한다. Zig write는 8 MiB UTF-8·Markdown·no-follow 정규 파일만 같은 디렉터리 fsync+rename-replace하고 macOS ACL/stat/xattr를 보존한다. dirty는 이탈 전 pending→hidden view snapshot→native ack의 2단계로 실패 중 eviction을 막는다. AppKit 도크 포커스 축과 retained modal guard가 workspace browser Cmd+R/←/→ 오라우팅을 막는다. merge는 도크 모델/live surface를 teardown 전에 옮기고 session-local LRU clock을 재정규화한다. 기본 live-view 8(1~256), dirty/pending 보호와 eviction 뒤 새 id를 테스트한다. 실제 WK smoke가 CM hydration과 isolated dirty→write 왕복을 단언한다. | 정상 창 닫기·`⌘Q`·terminal 자동 종료는 dirty/pending/source-edit entry를 fail-closed한다. dirty content의 workspace 영속·crash recovery는 제공하지 않는다. 동일 경로 양쪽이 dirty/pending/source-edit 보호 상태면 자동 선택하지 않고 merge를 거부한다. | `mise run web:check`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-app-smoke`, `mise run test`, `mise run check`. |
| 파일 패널 Markdown 리치 편집 | 진행 중 | 툴바 + 문서모델 WYSIWYG를 셋째 모드로 둔다(file-panel-rich-edit.md §2.5). 마크다운→문서모델→마크다운 왕복이 원문을 정규화할 수 있음을 계약으로 수용하고, 손실 0이 필요한 문서는 소스 모드가 받는다. 한글 IME 조합은 헤드리스로 재현되지 않아 GUI 손 테스트가 완료 조건이다. |
| 네이티브 편집기 — 미저장 내용 백업 | 구현 전 | 계약은 [native-editor-document-model.md](native-editor-document-model.md) §3.10(2026-08-09 사용자 결정 — 옛 "제공하지 않음"을 뒤집음). 헤드리스로 증명할 것: 전체 내용 + `disk_fingerprint` 기록·복원 왕복, **fingerprint 불일치 시 자동 복원하지 않고 선택을 요구**, 정상 종료·저장 성공 시 삭제, **undo 스택은 복원 대상이 아님**, 뷰가 여럿이어도 문서당 백업 하나(§2.4). | **자동 저장과 혼동하지 않는다** — 원본은 명시적 `⌘S`로만 쓰고(`file-panel.md` §1의 "focus-loss/autosave 없음"은 유효) 백업은 별도 파일이다. **실제 crash 복원은 헤드리스로 재현하기 어려우므로** 프로세스 강제 종료 후 재시작 시나리오가 손 테스트로 남는다. 큰 파일의 debounce 비용은 §3.0 축소와 연동되며 저하 시 상태바 고지(§2.2)가 완료 조건이다. | 미정(구현 슬라이스에서 확정) |
| 네이티브 편집기 — 같은 파일 두 뷰 | 구현 전 | 계약은 [native-editor-layering.md](native-editor-layering.md) §2.4(2026-08-09 사용자 결정)이고 `file-panel.md` §1 불변식에 명시 명령 예외가 붙는다. **모델 공유는 헤드리스로 증명한다** — 두 뷰가 같은 버퍼를 참조하는가(한쪽 편집이 다른 쪽 조회에 즉시 보임), undo/revision/dirty가 공유되는가, selection·스크롤·랩·접힘은 독립인가, **뷰 하나를 닫을 때 dirty 게이트가 걸리지 않고 마지막 뷰에서만 걸리는가**, rename이 **모든 뷰의 경로**를 갱신하는가, "경로로 열기"가 **가장 최근 활성 뷰**를 고르는가. | 불변식을 푸는 변경이라 **1:1을 전제한 조회가 남아 있으면 두 번째 뷰가 조용히 무시된다**(§2.4) — 경로→Term 조회 소비처를 전수 확인해야 하고, 그 확인은 헤드리스 테스트로 대신할 수 없다. 뷰 배치·포커스 전이는 GUI 손 테스트. | 미정(구현 슬라이스에서 확정) |
| 다국어(i18n) — UI 표시 문자열 | 부분 구현(I3-0 leaf + I3·I4 완료 + I3g 게이트(§7.1 축 포함) + I5·I2 완료 + I3b config 86 + I3c 65/76 + I3d session 27 + I4a 언어 선택) | 계약은 [i18n.md](i18n.md), 단계는 [plans/i18n.md](plans/i18n.md). **구현된 것**: `src/i18n.zig`(테이블·`t`/`tIn`·보간·`fromLocale`·`resolve`, 테스트 23)와 소비처 셋 — `reportFileTreeRootOutcome`(27건)·`settingsMessageOrNotice`(13건)·`showNoticeKey`(97건)·확인 대화상자(28건)·세팅 섹션 이름(13건). **`ui.language`(기본 `auto`)가 배선됐다** — 로케일은 Swift 가 읽어 `maru_macos_app_set_ui_locale` 로 넘기고 판정은 중립 층이 하며(계약 §5.1), 세션 init·파일 reload·GUI 변경 3 경로가 적용한다. 파라미터가 `Key`라 리터럴은 컴파일되지 않는다(변이 검증으로 확인). 값이 끼는 한 건은 보간 진입점 `settingsMessageOrNoticeFmt`가 받는다. **남은 것**: 언어 테이블 완전성(누락 시 `error: missing struct field` — `Table`에 기본값을 두지 않는 것이 근거), 런타임 보간의 어순 재배치(`"{1}…{0}"`)·인자 부족·잘못된 자리표시자·버퍼 부족 절단, 세팅 페이지 스냅샷 en/ko 2종, 기본값 `auto` + 한국어 로케일에서 **현재 화면과 동일**(퇴보 없음), 리터럴 게이트의 변이 검증(호출 인자·배열 대입 양쪽). | **자동 게이트가 완전 봉쇄가 아니다**(i18n.md §7.3) — 2차 리터럴 검사는 우변이 리터럴인지만 보므로 변수를 거치는 우회를 못 잡고, `context_menu_items_buf`처럼 정적·동적이 한 배열에 섞이는 자리는 타입 전환이 불가해 그 구멍이 영구적이다. **sink 목록이 수렴하지 않는다** — 전수 조사에서 세 번 넓혔고 매번 새로 나왔다. 그래서 대상 개수도 확정치가 아니라 **559~634 범위**이며 `data`에 남은 문장형 75건은 사람이 봐야 한다. 실제 번역 문안이 나오기 전에는 폭 위험·작업량을 추정하지 않는다. | I3g가 판정자 + baseline 원장을 세우고(늘면 실패, 원장 숫자가 진행률), 타입 전환이 끝난 경로부터 1차(컴파일러)로 옮긴다. |
| 네이티브 편집기 — tree-sitter 1층 | 구현 전 | **런타임 의존성 첫 예외**(2026-08-09 사용자 결정 — [native-editor-visual-mapping.md](native-editor-visual-mapping.md) §5.3, [project-rules.md](project-rules.md) §의존성). 헤드리스로 증명할 것: provider 계약(`init`/`onEdit`/`spansForRange`)의 증분 정합 — 편집 시퀀스 뒤 트리가 전체 재파싱 결과와 같은 스팬을 내는가, 문법이 깨진 입력에서도 트리가 나오는가(오류 복구), grammar 없는 파일이 무색으로 저하하는가. | **파싱 상한과 격리가 완료 조건이다** — grammar는 제3자 C 코드이고 문서 내용은 적대적일 수 있으므로(§3.8) 파서 실패가 편집기를 죽이지 않아야 한다. **번들 언어 목록과 grammar별 라이선스 확인**([third-party-licenses.md](third-party-licenses.md) 표 갱신)이 없으면 완료로 보지 않는다. 전 문서 파싱은 렌더 루프 밖(§2.1). | 미정(구현 슬라이스에서 확정) |
| 네이티브 편집기(등폭 GPU 뷰·편집·diff) | **N2 편집 축 완료**(2026-08-25 — caret·타이핑·삭제·undo/redo·저장. 남음: 커서 이동 일습·dirty 표시·한글 IME는 N3) · **N1 부분 구현**(제품 pane에 뜬다 — 선택·스레딩 남음) · **N1.5 a~e + 기본 경로 전환**(줄 대응 differ·네 상태 배선·좌우 렌더·밴드와 좌측 띠·문자 단위 강조 — 골든 `editor-diff-side-by-side`·`editor-diff-scrolled-bands`. **2026-08-18 기본이 네이티브다** — 전환 전 실제 클릭 경로를 캡처로 확인했고, CM6 대비 후퇴 중 **스크롤 축**(가로 막대)을 함께 채웠고 드래그도 그 뒤 붙었다. **텍스트 선택·복사도 섰다**(2026-08-20 — 아래 참조). **문서 내 검색(⌘F)도 섰다**(2026-08-23 — §5.1. 없던 기능이 아니라 **조용히 틀려 있던 것**을 고쳤다: 편집기 Term의 코어는 1×1 sentinel이라 ⌘F가 늘 0/0이었다. 일치 계산은 L2 순수(`session/editor/find.zig`, 대소문자 규칙은 터미널과 공유·정규화는 안 한다), 강조는 두 색, Enter/⇧Enter가 오가며 접혀 숨은 매치는 펴고 간다. 판정자는 `FND*`(L2 일치 계산)·`EF*`(키 이벤트 종단)·`EM*`(좌표·스냅숏)·`SRCH*`(그리기)로 갈리고, **그중 상당수가 적대적 검증에서 뮤턴트가 살아남아 뒤늦게 세우거나 다시 쓴 것**이다(여섯 라운드). **수는 여기 적지 않는다** — 옮겨 적었다가 한 번 틀렸고(34/열셋), 집계는 한 곳에만 두는 것이 맞다. 정확한 수는 PR #2586과 커밋 메시지가 소유한다. ~~남은 것: 바꾸기(버퍼 선행)·현재 일치가 selection을 옮기는 것(caret 선행)·정규식·스크롤바 마커·대소문자 옵션·비교 뷰 검색.~~ **여섯 중 다섯이 닫혔다**(2026-08-27~09-01): 바꾸기·현재 일치가 selection을 옮기는 것·스크롤바 마커·대소문자/낱말 옵션·비교 뷰 검색. 「선택 영역 내에서만」도 함께 섰다. **비교 뷰에서 어느 열을 검색 중인지도 화면에 뜨고 넘길 수 있다**(2026-09-02 — 왼쪽이 언제나 옛 판이라, 표시가 없으면 방금 추가한 이름을 찾다 만난 0을 설명할 길이 없었다. 열은 **찾기가 든다** — 읽는 제스처가 찾기 하나뿐이라 뷰 수명 축을 세우지 않는다). **남은 것은 정규식 하나**이고 엔진 결정이 선행한다. 그리고 "이미 보이나" 판정이 **줄 축**에서만 정확하다 — 조각·열·pane 폭·pane 높이는 §5.2의 2차원 reveal이 소유한다). `MARU_NATIVE_DIFF=0`으로 되돌릴 수 있다) | 계약은 [native-editor.md](native-editor.md)가 소유한다(2026-08-09 사용자 결정 — `text` kind와 diff 본문을 CM6에서 Zig+Metal로 이관, 마크다운 렌더는 웹 유지). 헤드리스로 증명할 것: L2 편집 연산·selection 병합/primary 승계·undo 그룹핑과 복원·byte↔논리행·줄별 폭 합(탭스톱 포함)·lexer 상태 전이, L3 랩/접힘/가상줄 매핑과 **조건부** 좌표 왕복(§10 — 무조건 왕복은 성립하지 않는다). **gutter 기하도 헤드리스다**(§4.1). **N1 몫**: 영역 순서(좌측 여백 → 줄 번호 → 접기 → 여백 → 본문 — 좌측 여백은 자리만 있고 아직 그리지 않는다), 줄 번호 최소 5셀과 자릿수 초과 시 확장, 접기 비활성 시 그 셀이 사라지는 것, git 마커가 **셀 폭을 먹지 않는 것**(기존 `GutterMark`와 같은 불변식), 본문·gutter 글자가 **셀 인덱스**로 놓이는 것(`Op.text.cell_w_px` — 탭 위치 계산과 실측 픽셀이 일치), 폰트를 키우면 글리프와 배치가 함께 커지는 것. **시각 골든도 함께 둔다** — `editor-gutter` Chrome Lab 시나리오가 1~12번을 한 화면에 담아 **우측 정렬과 9→10 자릿수 경계**를 픽셀로 고정한다(셀↔픽셀 변환이 어긋나는 회귀는 단위 테스트로 안 잡힌다). **N1.5 몫**: diff 좌우 gutter 폭이 서로 독립인 것, git 마커 대신 변경 종류 색 띠가 나오는 것. **N4 몫**: 진단 자리가 맨 왼쪽에 열리며 본문이 밀리는 것, 한 줄에 진단이 여럿일 때 severity 최고 하나만 나오는 것, 여러 줄 진단이 시작 줄에만 붙는 것. | **N1이 아직 계약을 다 만족하지 않는다** — [native-editor-document-model.md](native-editor-document-model.md) `§3.8`의 **가시화는 구현됐고**(BiDi·제어·폭 0·비표준 공백이 `<U+202E>` 표기로 드러난다, 골든 `editor-hazard-visible`) 초장문 줄 축소도 섰다. 남은 하나였던 깊은 중첩 상한도 접힘과 함께 섰다(`session/editor/fold.zig`의 `max_depth = 64` — 넘으면 그 아래를 안 접을 뿐 맨 바깥은 그대로 접힌다). **랩·스크롤바·세로 스크롤 입력·제품 pane 표시는 구현됐다**(2026-08-13~14 — 훅이 파일을 편집기 Term으로 열고 tick의 `appendPaneFrame`이 leaf마다 그린다. 배경 합성 층·본문 사각(`body`)·바탕색(`terminal_bg`)·창 투명도가 함께 확정됐다). **접힘도 구현됐다**(2026-08-17 — 들여쓰기 층 `fold.zig`, 전체·레벨 접기 명령, gutter 화살표 ▾▸를 늘 그린다, 골든 `editor-folded-gutter-arrows`. diff 상태에서는 원본이 없어 거절한다). **화살표를 눌러 개별 접기/펼치기도 된다**(2026-08-22 — `hitTestFoldMark`·`toggleFoldAtPoint`. §4.1f가 *"안 한다"*고 적은 근거가 *"포인터 경로가 없다"* 하나였고 §4.1g가 그것을 없앴다. 헤드리스로 증명한다: **그린 화살표 셀의 가운데를 눌러** 그 블록만 접히고 다시 눌러 펴지는가(그리는 열과 받는 띠가 같은 layout에서 나오는가), 접기 칸의 여백 칸도 받는가, 본문·줄 번호 칸·화살표 없는 줄·pane 밖·극단 좌표가 전부 거절되는가, **랩으로 이어진 조각**이 거절되는가. 같은 슬라이스에서 접기 칸이 1→2셀이 됐다 — 줄 번호가 우측 정렬이라 화살표가 번호에 맞붙어 있었다(사용자 지적)). **가로 스크롤바도 구현됐다**(2026-08-18 — 본문 아래 여백에 서고 자리를 먹는다. 골든 `editor-hscrollbar`). **줄별 행 수 캐시도 섰다**(2026-08-18 — `frame.RowCache`. 정지 상태에서 매 프레임 돌던 전 문서 계수를 없애 4,000줄 랩 문서가 프레임당 12.9ms → 0.2ms가 됐고, 계수 상한 `[4096]u32` 때문에 그 이상 문서의 시각 행이 근사돼 **스크롤바가 1.66배 길게 뜨던 결함**이 함께 닫혔다. §2.1 스레딩은 없어지지 않고 **리사이즈 드래그 중**으로 좁혀졌다). **폭 드래그 중 저하 동작도 섰다**(2026-08-18 — 사이드바 경계·pane divider·**dock 바깥 경계** 세 드래그가 폭을 라이브로 끄는 동안 계수를 보류하고 직전 결과로 그린다. 2만 줄 랩 문서 프레임당 60.9ms → 0.2ms. **창 리사이즈는 애초에 해당하지 않는다** — `windowDidResize`가 드래그 중 세션 resize를 보류한다). **점진 계수도 섰다**(2026-08-18 — 드래그를 놓는 순간 전 문서를 한 번 세던 것을 `count_chunk_lines`씩 나눠 센다. 2만 줄 랩 문서 62ms → 프레임당 6ms이고 약 10프레임에 정확해지며, 그동안 막대는 실제보다 짧다. **워커로 가지 않은 이유는 §2.1이 소유한다** — 랩 계수는 줄마다 독립이라 나눌 수 있고 스레딩 유지보수 비용이 이득보다 크다. 파싱(tree-sitter)은 나눌 수 없으므로 그쪽은 여전히 분리 대상이다). **스크롤바 드래그도 섰다**(2026-08-18 — 세로·가로 막대를 잡아 끌 수 있다. 세로는 px를 시각 행으로 나눈 뒤 접두합을 되짚어 `(논리 줄, 조각)`으로 옮기고, 가로는 열로 옮긴다. capture 수명·tick 소비 규율은 도크·사이드바와 **공유**하고 `offset_px` 해석만 갈린다. **비교 뷰도 좌우 각자 잡힌다**(2026-08-18 — 세로는 좌우 값이 같아 어느 쪽을 잡든 같은 곳으로 가고, 가로는 §3.5대로 잡은 열만 민다) — [scroll-area.md](scroll-area.md) 소비자 표. 그 계약의 **가로 축을 이 소비처가 열었다**(§2.0)). **탐색기 클릭이 네이티브 편집기를 연다**(2026-08-19 — 파일 Term의 단일 분기점에 비교와 같은 자리를 하나 더 열었다. **기본이 네이티브다**(사용자 결정 — 계획은 N2에 두었던 전환이다). 대가는 분명하다: `.text`는 CM6에서 편집·저장이 되는데 N1은 읽기 전용이라 **탐색기에서 연 파일을 고칠 수 없다**. `MARU_NATIVE_TEXT=0`이 되돌리는 길이고 그것이 지금의 편집 수단이다. 못 읽는 파일은 CM6로 폴백하고, 브리지 술어는 entry 단위로 올라갔다 — 위 파일 패널 행). **웹뷰를 떠나며 못 채웠던 텍스트 선택·복사가 2026-08-20에 섰다** — 드래그로 고르고 `Editor: Copy Selection`으로 뜬다. CM6에서는 WebKit이 주던 기능이고, 그 자리를 포인터 경로(§4.1g 배선)가 채웠다. **키 입력 경로는 여전히 없다** — ⌘C 기본 chord가 없는 이유가 그것이다(터미널 선택이 쓰는 키인데 편집기 Term 컨텍스트가 없어 조건부로 양보할 수 없다. N2의 몫). **본문 hit-test는 2026-08-19에 섰다**(§4.1g — 화면 좌표를 문서 offset으로 옮긴다. 회차와 결함 수는 [plans/native-editor.md](plans/native-editor.md) N1이 단일 출처다) — **그 배선이 2026-08-20에 붙었다** — 단일 편집기에서 드래그 선택·하이라이트·복사가 된다. ~~**비교 화면은 아직이다**(좌우 어느 열인지 정하는 결정이 남았고, 가로 스크롤 입력이 같은 이유로 비교를 뺐다).~~ **비교 화면도 섰다**(2026-09-02 정정 — 실측: `editor_diff_selection`·`buildDiffSelectionMarks`·`copyDiffSelection` 이 다 있고, 가로 스크롤도 `isRightColumn` 으로 열마다 민다). 이 문장은 **그 결정이 난 뒤에도 남아 있었다.** 스크롤바는 **chrome**이라 그 결정과 독립적으로 먼저 열 수 있었지만(위), 본문 선택은 **커서를 어디에 놓느냐와 같은 좌표계 결정**이라 그렇지 않다. N1.5의 "검토 흐름이 네이티브로 닫힌다"는 이 항목까지 서야 온전하다. ~~**상태바 커서 항목·선택 하이라이트가 남았고**,~~ **상태바 커서 항목은 섰다**(`ItemId.editor_cursor`), 진행 표는 [네이티브 편집기 구현 계획](plans/native-editor.md) N1이 소유한다. **§3.8은 "읽기 단계부터 필요하다"고 그 절이 못박은 것이므로 N1 완료 판정의 조건이다.**

**착수 전 gate는 없다**(2026-08-23 사용자 결정 — [native-editor-document-model.md](native-editor-document-model.md) §3.0). 버퍼 표현은 1순위가 rope이고, **무엇을 보면 뒤집는지**를 §3.0이 표로 든다(편집 누적 후 열화·스냅샷 메모리·`line_index` 흡수 실패·프레임 예산 초과). 이 원장이 지는 몫은 그 신호가 나타나는 슬라이스에서 **확인했는지**다.

**이관 효과의 성능 baseline은 재지 않는다**(2026-08-09 사용자 결정 — 옛 "착수 전 gate: CM6 3축 측정"을 철회). 계측 하니스가 이 작업 대비 과하다고 판단했고, 그 대가로 **이관 효과를 성능으로 주장하지 않는다**(성능을 근거에서 뺐다 — native-editor.md §1.0). 남는 한계는 네이티브 경로가 더 느려져도 그것을 가리키는 수치가 없다는 것이며, 방어는 손 테스트뿐이다. **헤드리스 불가**: IME(특히 중간 caret 조합 — 현행 `NSTextInputClient`가 `replacementRange`를 무시하고 `markedRange().location`이 0 고정), 멀티 커서 × IME(정책은 "primary만 조합 → 확정 시 복제"로 확정됐고 실측은 그 검증이다), 커서 blink(ABI 단일 구간 전제 확장), 실제 GPU 출력. 터미널 IME 무회귀가 최대 리스크다. | 미정(구현 슬라이스에서 확정) |
| 선택 영역을 에이전트에 보내기 | 설계 확정, 미구현 (**네이티브 편집기부터** — 2026-08-30 사용자 결정) | 편집기나 파일 패널에서 고른 부분을 **그 창에서 고른** 터미널 CLI에 붙여넣는다([send-selection-to-agent.md](send-selection-to-agent.md)). 경로가 둘이고 **네이티브 편집기가 1차**다 — 재료(선택·줄 인덱스·핀된 경로)가 이미 서 있고 층이 셋 적다(render iframe·신뢰 shell·브리지 epoch 검증이 없다). 슬라이스는 그 문서 §6.1(NS1~NS5)이 소유한다. **NS3·NS4 완료**(2026-08-30): 후보 순서·경로 접기(`session/agent_selection.zig`)와 **편집기 본문 우클릭 메뉴**가 섰다. 그 전에는 편집기 본문 우클릭이 터미널 본문 분기로 내려가 `input.right-click=paste` 기본값에서 **문서에** 클립보드를 붙여넣었다(PTY로 새지는 않았다 — `pasteText`가 편집기 Term을 알아본다). 그 자리를 가져오며 **`select_all`이 편집기만 빠져 있던 것**도 함께 고쳤다(주소창·커밋 상자는 분기하는데 편집기는 코어 큐로 보내고 있었고, 편집기 코어는 sentinel이라 ⌘A가 아무 일도 안 했다). 남은 것은 NS5(보내기 항목 + 주입)다. 선택 수집은 web, 정책·대상·주입은 Zig다 — web은 임의 경로나 대상 surface를 지정할 수 없다. 안전 계약의 핵심은 **페이로드 끝에 개행을 넣지 않는 것**과 bracketed paste가 꺼진 대상에는 여러 줄을 보내지 않는 것이다(터미널 주입은 명령 실행이 될 수 있다). 개행 부재는 macOS 스모크가 PTY에서 직접 확인한다. 읽기·소스 두 모드만 대상이고 리치는 원문 줄 역매핑이 없어 제외한다. |
| 파일 패널 Markdown 읽기·리치·소스 | 구현(ABI v150) | Markdown mode는 `read`(기본)·`rich`·`source-edit` 셋이고 workspace restore는 저장 mode를 따른다. 폐기된 `live-preview`가 저장된 옛 파일은 reader가 `defaultFor`로 clamp한다. 탭 이탈 dirty-sync 요청은 Zig one-shot 하나가 소유하고 Swift/Web이 surface당 pending/in-flight Promise 하나로 반복 전환을 coalesce한다. shell hydration은 renderer-ready와 분리된 단일 mutation queue에서 `beginDocument({ document_id })`→`read({ editor_epoch })`를 수행하며 hook-missing만 100ms×40회 retry하고 성공한 epoch-scoped `setDirty` ACK에서만 보호를 해제한다. surface-local document id는 begin 재시도에 idempotent하고 이전 document의 늦은 begin/read/ACK를 거부한다. exact editable WebContent termination은 ABI v135를 거쳐 ACK 전 편집 가능성까지 `editor_recovery_required`로 fail-close한다. **세 모드의 기준점**: 읽기·소스는 같은 CM6 `Text`/revision을 공유하고, 리치는 문서모델이라 직렬화 결과를 `savedContent`와 견준다. 모드를 벗어날 때 그 시점 마크다운 한 벌을 상대 편집기에 넘기고(§2.5), 저장은 호출 시점 mode를 고정해 큐 콜백이 다른 모드의 기준점을 갱신하지 않는다. 외부 디스크 reload는 CM6와 리치를 **모두** 다시 시드한다 — 한쪽만 갱신하면 다음 저장이 외부 편집을 되돌려 쓴다. close lock과 IME fail-closed 판정은 지금 보이는 편집기를 본다. **문법 목록으로 편집을 막던 잠금은 없다** — [file-panel-rich-edit.md](file-panel-rich-edit.md) §2.5의 원문 보존 규칙이 대체했다(2026-08-02). 문서모델이 모르는 구간은 불투명 노드(`rich-raw-node.ts`)가 원문 문자열로 통과시키고 직렬화가 글자 그대로 되쓴다. `unsupportedRichSyntax`·잠금 안내·저장 거부·`onLockChanged` 배선은 전부 제거했고, 이제 리치를 잠그는 유일한 이유는 close lock이다. 블록 조각은 마크다운 토크나이저가 주는 `html` 토큰을, 인라인 조각은 **우리가 발행하는 토큰**을 받는다(라이브러리 인라인 파서가 `html`을 하드코딩 처리해 등록된 핸들러를 부르지 않는다). 각주는 토큰조차 아니라 토큰 규칙을 더해 인식시킨 뒤 같은 노드가 받는다. 왕복 실측: `<details>…</details>`·`<kbd>⌘S</kbd>`·`<br>`·`[^1]`+정의가 전부 원문 그대로이며, 블록 사이 빈 줄 하나 추가는 기존 정규화 등급이다. **frontmatter는 잠그지 않고 지원한다**(2026-08-01) — 가르기는 마크다운 파서가 아니라 문서 맨 앞이라는 **위치**가 하고(`frontmatter.ts`, 본문 중간 `---`는 구분선으로 남는다), 전용 블록 노드가 안쪽을 **평문 그대로** 왕복시킨다. 읽기 모드는 그 블록을 문서 맨 위의 **메타데이터 표**(`maru-frontmatter`)로 그리며 값은 해석하지 않고 원문 그대로 옮긴다 — 그 전에는 `<hr>`+`<h2>title: 문서`로 새어 나왔고, `remark-frontmatter`만 넣으면 반대로 출력에서 사라진다. **읽기 모드는 문서가 직접 쓴 HTML을 그린다**(2026-08-02) — `rehype-raw`로 판독하고 무엇이 살아남는지는 `rehype-sanitize` allowlist가 단독으로 정한다(`script`·`style`·`iframe`·`form`·`on*`·인라인 style은 계속 제거, `style`은 안쪽 내용까지). renderer-owned `data-maru-source-*`/`data-maru-asset-*`는 붙이기 전에 지워 문서의 위조를 덮는다 — 특히 asset 경로는 viewer가 `readAsset` 인자로 쓴다. 리치는 저장 왕복 때문에 계속 잠근다(판단 근거가 다르다 — 읽기는 "안전하게 그릴 수 있는가", 리치는 "잃지 않고 되쓸 수 있는가"). Markdown 파생 DOM은 6-field capability의 bridge-free renderer에만 넣는다. |
| 파일 패널 FP12~FP15 VSCode형 다중 파일 종류(text/code·svg·image·media·pdf) | 구현(FP12·FP12b·FP13·FP14·FP14b·FP15) | 계약은 [file-panel-kinds.md §2.2](file-panel-kinds.md)가 소유한다. kind 분류는 `file_panel_bridge.openKindForPath` 하나가 결정하고(`OpenKind = markdown, html, text, svg, image, media, pdf`), L2 모델은 `dock_panel.EntryKind`/`Mode.defaultFor`/`allowedFor`/`usesEditorBridgeByKind`가 kind별 불변식을 고정한다. **브리지 술어만 entry 단위다**(`Entry.usesEditorBridge` = kind 술어 ∧ `!native_editor`) — `.text`는 네이티브 편집기로도 CM6로도 열려(`MARU_NATIVE_TEXT` — 기본이 네이티브) kind가 그 둘을 가르지 못하고, kind로만 판정하면 닫기가 오지 않을 CM6 스냅샷을 기다려 **네이티브로 연 탭이 닫히지 않는다**. **FP12 text/code**: `TextLanguage`/`textLanguageForPath`(txt·json·js/ts·py·css·xml·yaml 큐레이션)로 신뢰 config(`filePanelKind=1`)에 `?lang=` 힌트를 실어 CM6 하이라이트를 붙인다. **FP12b**: syntax 색을 터미널 테마에서 파생해 CSS 변수로 주입한다. **FP13 svg**: read(격리 sanitize→data URL `<img>`)+source(xml) 두 mode, 헤더 mode 선택기는 `modesForKind`로 kind별 일반화. **FP14b·FP15**: image·pdf·media는 모두 격리 `loadFileURL` 경로(`filePanelKindIsIsolated`→`panel_kind=browser`)로 통일했고 read 전용이라 dirty/save 경로가 없다. media는 wrapper+`MediaError` 대신 **확장자 allowlist 사전 판정**(`mediaExtension`, OS 코덱만)을 쓴다. | 실제 렌더·재생·코덱 지원 여부·`loadFileURL` 동작은 헤드리스로 증명되지 않는다. WebM 등 OS가 디코드하지 않는 포맷은 allowlist 밖으로 두어 외부 앱으로 폴백하므로, 코덱 판정의 정확도는 allowlist 큐레이션 품질에 묶인다. | L2 자동 게이트(kind 분류·persist round-trip·mode 불변식·용량 거부) + macOS GUI 손 테스트(FP12·FP13은 2026-07-29, FP14는 2026-07-23 사용자 확인). |
| 파일 패널 FP7 Zed형 프로젝트 트리·watcher | 구현(FP7, Zig+FSEvents+AppKit) | L2 `file_tree.zig`이 Zed형 exclusion/natural sort/lazy folder+symlink/multi-root/recent MRU와 open/active/dirty/conflict row를 소유한다. root≤256·node≤16,384·child≤4,096·request≤1,024이며 overflow는 모든 root 재스캔으로 회복한다. L4 worker는 openDir/iterate/stat을 동시 4개로 수행해 고정 완료 queue≤16만 tick에 넘기며 backend generation retirement는 main actor에서 worker를 기다리지 않는다. **ET-CWD**(2026-08-31 결정)는 활성 workspace→pane→Term의 CWD가 변할 때만, 그 CWD 폴더 자체를 explicit root로 교체한다 — 저장소 루트로 올리지 않고 홈·`/`도 예외가 아니다. 교체는 사용자 picker와 같은 검증 파이프라인(`provideFileTreeRootPick` + `.replace`)을 타고, 도크가 보이고 view가 탐색기이며 namespace mutation이 없을 때만 건다. root가 이미 그 CWD면 no-op이고, 못 건 CWD는 followed로 표시하지 않아 다음 tick이 재시도한다. CWD 해석은 OSC 7 관측 뒤 커널 조회 폴백이며 main actor가 renderer보다 먼저 observation cache를 읽는다. 파일/브라우저 Term은 CWD가 없어 직전 값을 유지한다. target이 viewport 안이면 scroll을 보존하고 밖일 때만 최소 scroll한다. ABI v123 + Swift FSEvents(file events/watch-root, 200ms)가 root reset/add와 changed path를 전달하고 dropped/must-scan/root-change는 coarse rescan, stream rebuild는 event ID 연속성을 쓴다. 도크 우측 tree는 기본 18셀·최소 12셀이고 editor 최소 28셀을 우선 보장한다. editor/tree divider 드래그는 첫 이동 무점프·WebView live reframe을 보장하고 조절 폭(pt)을 `dock-tree-size`로 단일/다중 그룹 workspace에 왕복한다. tree row는 active/hover 배경과 클릭/접기/스크롤 rect를 공유하며 partial row는 hit-test에서 제외한다. clean Markdown/HTML은 reload하고 dirty/pending은 buffer 보존+`external_change`+저장 거부, 헤더 `!` 확인 뒤 web read/replace 성공 ack가 와야만 dirty/conflict를 해제한다. short ABI output은 required length를 반환하고 one-shot을 보존한다. | 실제 FSEvents delivery wall-clock과 대형 repo event→snapshot p95 수치 예산은 아직 없다. macOS GUI에서 symlink 밖 root를 펼친 뒤 외부 대상만 변경하는 경우 별도 watcher root 추가는 후속이다. **ET-CWD의 GUI 경로에는 자동 E2E가 없다** — 통합 test가 제품 관측(실제 OSC 7 write)과 `updateFileTree`까지는 타지만, FSEvents watcher 재등록과 Metal 렌더 결과는 확인하지 않는다. 아래 2026-08-31 수동 확인이 그 간극을 **1회 관측**으로 메웠을 뿐 상시 게이트가 아니다. 빠른 `cd` 연타의 watcher 재등록 부하와 홈·`/`가 root일 때의 첫 스캔 비용은 재지 않았다. 심볼릭 링크 cwd는 root가 realpath로 정규화돼 `rootIsExactly`가 계속 거짓이라, 같은 자리로 돌아올 때마다 재교체가 걸린다(조용한 비효율 — 고치지 않았다). | `mise run test`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-app-build`, `mise run web:check`, `mise run check`; AppSession ET-CWD 통합 test가 active pane OSC 7 refresh, root가 이미 그 CWD일 때의 no-op, 하위·상위·형제 이동 전부에서의 교체 제출, mutation busy·비탐색기 view에서의 미룸과 재시도, visible target 무스크롤, split active pane과 web Term 유지를 고정한다. 후속 성능 smoke는 event→snapshot p95/tick drain artifact를 추가한다. **2026-08-31 실제 앱 수동 확인**(`zig-out/Maru.app`, 격리 HOME + `MARU_SCREENSHOT` 지연 캡처, AppleScript 키 입력): ⑴ 시작 cwd(`…/maru5`)가 그대로 트리 root, ⑵ `cd src` 가 저장소 루트로 올라가지 않고 `src` 를 root 로 세움, ⑶ `cd /Users/<user>` 가 홈을 root 로 세움(예외 없음), ⑷ 홈에서 `cd Documents/workspace/maru5` 로 **빠져나옴** — 2026-08-11 계약의 홈 흡수 상태가 해소됐다. GUI 자동화 하네스가 없어 재현 스크립트가 아니라 1회 관측이다. |
| 파일 패널 FP8 도크 editor group split | 구현(FP8, Zig+AppKit) | `DockPanel.focused_group`과 64-group bounded preorder persistence를 추가하고 단일 그룹 legacy wire는 유지한다. `dock_layout.groupGeometry`가 leaf별 tab/header/content를, `layoutDividers`가 1px 경계·확장 hit target·drag ratio를 공유한다. 여러 그룹의 active WKWebView는 divider drag 중에도 visible을 유지하고 각 rect로 live reframe한다. 내부 divider도 mouse-down offset을 보존해 grab slop 어느 지점에서 시작해도 비율이 점프하지 않는다. ABI v124가 native firstResponder surface를 Zig group focus로 동기하고, 팔릿 split/close command와 dirty-safe close를 제공한다. 사용자 제공 Artifact 구조 기준으로 고정폭 파일 탭·breadcrumb·렌더/편집 선택지·독립 탐색기 헤더·project-first/recent-last 순서를 고정하고, outer/group/tree divider의 정확한 선과 WKWebView 안쪽 grab band 모두 내부 도크 hit-test보다 먼저 resize를 시작한다. 각 leaf의 실제 맞닿는 seam 비트를 단언해 WebView가 확장 hit band를 삼키는 회귀를 막는다. 창 병합은 destination split을 유지하며 source entry/live surface를 포커스 그룹에 평탄화한다. | source 창의 group 배치 자체는 창 병합 시 보존하지 않고 destination layout을 우선한다. FP9부터 명시적 split은 active entry를 새 group으로 옮기며, 유일한 entry라 빈 sibling만 생기면 no-op이다. 색상은 Artifact 고정값이 아니라 기존 theme를 따른다. | `mise run test`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-app-build`, `mise run macos-app-smoke`, `mise run check`. |
| 파일 패널 FP9 파일 탭 drag·dock-local split·입력 포커스 인지 | **FP16에서 폐기·흡수됨**(아래는 폐기 시점의 계약 기록) — 파일 탭 드래그·재정렬·pane 간 이동·drop split은 이제 terminal 탭 드래그가 단독 소유하고, `dock_drag.zig`·`DockPanel.commitEntryDrop`·`DockDragGeometrySnapshot`·`DockAsyncToken`과 그 invariant 테스트는 삭제됐다. 현재 계약·검증은 "파일 패널 FP16" 행을 본다. 기반이던 ABI v131·v136은 유지 | [file-panel-dock-ui.md §3.3](file-panel-dock-ui.md#33-파일-탭-드래그도크-내부-분할)의 `FP9-MODEL/WIRE/ID/BARRIER/GESTURE/TXN/CAP/GEO/DOMAIN/SEAM/SURFACE/EVICTED/FOCUS/EMPTY/PERF`가 typed terminal↔dock 격리, 기존 workspace wire 저장, 앱 전역 stable entry ID, restore/merge transient barrier, 원자 drop, 4방향 split, geometry snapshot, WebView divider grab, surface/focus/빈 그룹 수명을 소유한다. §3.4는 overlay-aware `FocusOwner` 파생 theme focus border와 기본 `⌘⇧E` `toggle_file_panel_focus` 왕복을 소유한다. workspace target은 active leaf에서 tab bar만 제거한 `PaneGeometry.body`이며 `.grid`와 WKWebView의 window padding은 border 안쪽에 남긴다. 전역 모달은 terminal과 dock을 합친 `Geometry.workspace` 중심을 쓴다. | terminal과 dock은 `SplitTree` 패턴만 공유하고 typed 모델·drag target·transaction을 분리했다. `PointerGestureOwner` variant가 단계와 payload를 단독 소유하고, `DockAsyncToken`은 surface-less native focus를 `EntryId`·surface·epoch·revision으로 재검증한다. 추가 빈 source leaf는 close/drop transaction과 restore publish 전에 collapse하고, 전체가 비면 단일 모델 루트만 유지한 채 workspace 입력으로 복귀한다. `close_focused`는 WebView surface provenance와 Metal terminal provenance를 각각 재검증해 stale `FocusOwner`가 다른 domain의 close를 실행하지 못하게 한다. 기존 workspace wire/version·하위버전 adapter는 추가하지 않았다. L4 `AppSession.paneGeometry`가 `PaneGeometry { bar, body, grid }`를 한 번 투영하고 renderer는 padding을 역산하지 않는다. terminal grid와 workspace/dock WKWebView는 공용 `layout_math.insetRect`를 소비하고, web chrome/seam 제거는 `web_panel_layout.contentRect`가 소유한다. Zig가 최종 padded frame과 실제 pane/outer/group/tree hit target의 edge별 교집합만 ABI v136으로 내리고 `WebPanelHitTestGeometry`는 superview 좌표의 point/frame과 그 폭만 소비한다. border는 `window_focused`와 현재 frame의 증명된 active leaf가 있을 때만 그려 비-key/OOM에서 fail-close한다. | [file-panel-verification.md §11](file-panel-verification.md#11-테스트검증)의 invariant 표를 ID별 gate로 자동 검증한다. C/Zig/Swift v136 edge band ABI, 0/비대칭/과대 padding과 1×/1.5×/2×에서 `native pass-through ⊆ Zig target`, nonzero-origin Swift hit-test와 일반 본문 클릭·휠 보존, exact surface transition을 증명한다. boundary 보정은 close/drop/restore의 빈 leaf 정규화, terminal-source `⌘W`의 Markdown confirm 0, WebView-source `⌘W`의 exact surface close, workspace/dock WebView inset, right/bottom 도크를 포함한 모달 중심, pane bar/body/grid 보수 관계를 고정한다. 비-key 창과 active-leaf layout/identity 실패는 border 0, 다음 정상 frame은 복원을 증명한다. 기존 chrome leaf 순회 융합과 projection seam 1,024-pane×1,000회 allocation 0, focus 왕복 WebView transition 0도 계측한다. |
| 윈도우와 surface 이동성(detach/reattach) | 구현 (M0~M3c 소유·라우팅·정규화 + **M3d cross-window 이동(트랜잭션 코어·라이브 workspace 수술·Swift 메뉴 GUI) + M3e 재시작 유지·활성 창 focus** — 남은 건 M3d-2a-ii pane/그룹 이동·드래그 M4~6·web Phase 4) | [윈도우와 Surface 이동성](window-surface-mobility.md)이 SurfaceIdAllocator, WindowMembershipSnapshot, AppRuntime, LiveSurfaceRegistry, WindowGraph, 앱 전역 `surface_id + generation`, cross-window drag/command UX, browser surface 재합치기 정책을 정의한다. **구현됨(L2 + L4 production 배선, 테스트 커버)**: M0a `SurfaceIdAllocator`(`src/session/surface_id.zig`, 앱 전역 단조·비재사용, `app_session.zig`가 `createTerm`에서 발급)·M0b `WindowMembershipSnapshot`+`WindowKind`(`window_membership.zig`, scope 필터)·M1 `WindowGraph`(`window_graph.zig`, move/merge/prune/focus 순수 트리, OOM 롤백 회귀 포함)·M2a `LiveSurfaceRegistry`(`live_surface_registry.zig`, generic 런타임 소유 골격, 주소 안정성·cross-window 이동 identity 보존 TDD)·**M2b·M3a Surface/live-PTY 소유권 production 이전**(`Term.surface`·`live_pty`가 이제 앱-전역 `app_runtime.live_registry`의 `LiveSurface` 번들 슬롯 소유, Term은 안정 슬롯 포인터로 참조 — createTerm/teardown 재배선, reader 교차바인딩 불변식·스크롤백 보존·`zig build macos-app` 실측)·**M3b `SurfaceRuntime` 앱-전역 라우팅**(per-window→`AppRuntime` coordinator `src/app/app_runtime.zig`={surface_ids, live_registry, routing}, 모듈-로컬 `var app_runtime` 소유·전 창 공유; 입력/resize/명령/PTY 이벤트가 surface_id 키드 한 표로 라우팅돼 창이 격리됨)·**M3c 그룹 정규화 L2 리프트**(`group_normalize.zig`, `inheritGroupMarker`·`normalizePinnedFromGroups`·`effectiveDepthAt`·`clearStaleLocalPins`·`enclosingGroupMarkerIndex`를 generic 순수 함수로; `moveWorkspace`가 §4 (a)~(d) 정규화 호출·red→green non-vacuous; L4 `app_session` 5메서드 본문 위임으로 `closeTab`/`removeFromGroupForTab` 재사용·기존 sidebar 그룹 테스트 green 유지). | **M0a로 `surface_id`는 이제 앱 전역 유일**(옛 per-session `next_id` 충돌 해소). **M2b·M3a·M3b 머지로 Surface/live-PTY 소유는 앱-전역 `LiveSurfaceRegistry`, 라우팅(`SurfaceRuntime`)은 앱-전역**이 됐다(사용자 가시 변화 0의 소유·라우팅 디딤돌 — registry·routing 배선 완료). **M3d·M3e 배선 완료**: M3d-1 이동 원자 트랜잭션 헤드리스 코어(`surface_move.zig`)·M3d-2a-i 라이브 workspace 이동 Zig 수술(`moveWorkspaceToSession`/`mergeSessionInto`, 무재시작=registry/routing/surface_id 무접촉·스크롤백 보존)·M3d-2b Swift NSWindow 배선(Window 메뉴 "Move Workspace to Window N"[카드 하나]·"Merge Window Into N"[창 전체], `active_workspace_index` getter)로 **GUI에서 cross-window 워크스페이스 이동 실동작**. M3e는 `WindowGraph` v2 전환(과설계·기각) 대신 `maru.workspace.v1` 옵션 필드 `active-window`로 **활성 창 focus 재시작 유지**(하위호환). 라이브 배치 권위는 per-window 트리 유지(§8A.6). 남은: **M3d-2a-ii**(pane/surface·그룹/pinned 라이브 이동), 드래그(M4~6), web(Phase 4). | Phase 1 live collector 전에 M0a/M0b를 선행한다: `SurfaceIdAllocator` opaque u64 비재사용, `WindowMembershipSnapshot`으로 `metadata:self/window/all` 필터. Phase 4 WKWebView hosting 전에는 M0 완료를 확인하고 M1/M2를 선행한다: WindowGraph 순수 move/merge/no-op/focus 단위, LiveSurfaceRegistry 분리와 surface 이동 후 PTY/TerminalCore 유지. Phase 4를 Phase 1보다 먼저 잡으면 M0a/M0b도 먼저 닫는다. M3 command/menu 기반 이동은 Phase 4 이후에 따라와도 된다. 이후 M5 cross-window AppKit drag, M6 WKWebView reparent/focus/bridge 검증을 붙인다. |
| 영속 터미널 세션 호스트·외부 attach | **P1·P2 완료, P3 core opt-in 구현, P3-e4a~d 완료, P4 L0·R3/R4 완료·R1 core + actual AppKit 다회 재실행 완료(Developer ID 미완)·R2a core/ABI/source-order + actual AppKit checkpoint file E2E 완료·R2b core+wire·secure discovery/ephemeral collector·CR6a-1 app-global projection owner·CR6a-2 launch collector/primary typed sidebar·CR6b explicit one-item adopt·C1 pure checkpoint coordinator·C2 atomic checkpoint file adapter·C3 background product wiring·C4 final-Quit handshake·CR6f E1 output wake·E2a cache transaction/E2b product wiring/E2c artifact·cap 구현·T0a ConnectionSlot reactor core·T0b0 global subscription identity·T0b1 readiness-turn·T0b2a daemon resource ledger·T0b2b daemon poll owner·T0b2c lifecycle 수렴 구현·나머지 미완료, P5a~P5c 구현·P5d provisioned Developer ID gate 미완료** | [영속 터미널 세션 호스트](persistent-session-host.md)가 Maru-owned `host_id + runtime_id`, host-owned PTY·`TerminalCore`, GUI detach/reconnect와 향후 `maru attach`를 정의한다. 구현된 P3 경로는 detached `maru-sessiond`, MRSH v2 strict spawn, 앱 전역 connection/backend, controller attach/input/resize, snapshot/delta·scrollback·selection/copy/search·kitty image·OSC metadata/notification pull, 정상 Quit detach와 workspace `runtime-handle` 재접속이다. restore-aware AppSession은 성공 재접속 전에 throwaway PTY를 만들지 않는다. per-Term ended placeholder와 `⏎` 제자리 재생성, typed attach 실패, exact handle + `runtime-state="ended"` reader/writer/capture와 두 cycle side-effect-free restore fixture, current+N-1 adapter/host-pool·same-PID exec 기반도 구현됐다. R2a는 exact full handle 전역 유일성, legacy bare/full 양방향 모호성 거부, 4,096 binding cap, allocator fail-index와 assembled snapshot의 Zig semantic preflight를 제공한다. R2b core+wire는 ID-only `runtime.inventory`, host별 256-item/16-page cap과 reconcile 시 전체 4,096-item 사후 거부 primitive, membership/authority/adapter/workspace generation, same-PID handoff generation 보존과 side-effect-free binding/orphan reconcile을 제공한다. CR6a-2는 launch-before-terminal 제품 coordinator와 primary-only `Recovered Sessions` projection을 연결하고, CR6b는 실제 click/검색 Enter에서 하나의 absolute deadline으로 fresh authority를 재검증해 orphan tab 또는 exact ended slot 하나만 채택한다. backend-neutral observation은 sidebar cwd/Git·agent·SSH upload·title·prompt 판단의 SSOT다. P4 L0는 manifest sibling `workspace.v1.lock`의 secure process-lifetime writer lease를 Window/AppSession/config/restore/runtime보다 먼저 획득하며 실제 이중 실행 loser를 side-effect 없이 거부한다. tmux ID/driver/wire와 provider resume/fork는 canonical 경로에 없다. | 설정은 아직 기본 `false`다. quick은 항상 in-process이며 Quit 때 종료하고 완료 조건이 아니다. durable tombstone의 실제 Developer ID signed app Quit/relaunch E2E와 config provenance A→B rollout은 P4 미구현이다. `ScreenInbox` 단일 owner와 deferred resync는 Debug·ReleaseFast `test-session-host-p4-r3-screen-inbox` 및 전체 `test-session-host`로 구현·검증됐다. **GUI 0 OS 배너는 「미구현」이 아니라 「OS gate 미완료」다** — daemon 안 발화·stable route·cold-click attach 는 구현·자동 검증까지 끝났고 남은 것은 provisioned signed runner 의 실제 Notification Center artifact 다(아래 §P4 N3 가 단일 출처). **2026-08-29 코드 대조 정정:** single-connection nonblocking `ConnectionSlot`은 제품 daemon 에 배선돼 있고(`daemon.zig` 의 `poll_owner.Owner.init`), async SSH action, 재접속 destination 복원, 두 Term destination/control-socket 격리가 P3-e4d-3/e4d-4 제품 E2E까지 구현됐다. echo-latency perf 는 `session host slow observer macOS` 가 median 10ms·tail 20ms 상한으로 CI 게이트를 소유하며 실측 median 0.86ms·max 5.17ms 로 통과한다(옛 21~23ms 는 cadence-only 구조의 값이다). Developer ID 서명은 `release.yml` 에 있으나 그 워크플로가 세션호스트 E2E 를 돌지 않아, signed app 게이트는 여전히 미충족이다. P5의 T0a OS-neutral slot/queue/scheduler core, T0b0 connection-local stream↔distinct global SubscriptionId 권위, T0b1 transactional readiness-turn adapter, T0b2b single-owner multi-fd product reactor까지 구현됐다. P5a2 read admin CLI와 P5a3 mutating admin CLI는 구현됐다. public attach는 P5c3d까지 구현되어 parser/help, pre-raw 4-phase attach, 단일 `IntegratedStackOwner`의 실제 poll/cleanup/signal loop와 built `maru attach` 제품 caller가 열렸다. Debug·ReleaseFast actual-`openpty` gate가 controller/observer, raw 입력, partial stdout, local detach, SIGTERM 전달과 termios 복원을 검증한다. P5c3d의 built host/runtime/attach-child 호환성 E2E와 P5d의 ad-hoc bundle/PATH·harness-owned localhost SSH packaging은 구현됐고, P5d provisioned Developer ID artifact 재실행은 미완료다. T0b2c cross-connection lifecycle은 구현됐다. T0b2a는 live runtime 256개와 aggregate grid 4,194,304-cell owner ledger를 구현했다. `workspace-binding-id`와 collaborative multi-app writer는 기본 전환 선결이 아니다. 현재 local fallback은 one-shot notice뿐이며 persistent `not preserved`가 남아야 한다. host/runtime crash·재부팅 뒤 동일 session 복구, cross-UID grant, persisted Mirror Term, web/file surface는 비목표다. | 현재 gate는 `zig build test-session-host`, `zig build test-macos-app-host-abi`, `mise run test`의 strict framing/spawn, 독립 host process spawn/attach/input/resize/snapshot/delta/reconnect, rollback 생존, stale identity, 앱 전역 keep-alive/quick local Quit, workspace handle round-trip, durable tombstone malformed/duplicate scalar fail-close·exact two-cycle capture/restore·restoreSpawn sentinel 0과 `macos-session-host-r1-tombstone-smoke`의 actual AppKit 두 번 capture→atomic checkpoint·직접 child 0·생성본 byte equality, `test-workspace-checkpoint-coordinator`의 Debug·ReleaseFast 11개 runtime+1개 layering gate가 stale/overlap, injected debounce와 capped backoff, failure epoch notice 1회, copied/reordered completion mutation 0, final capture/write 실패의 Quit 취소·detach 0과 final 중 mutation 재캡처을 검증한다. C1은 파일/AppKit/시계를 모르는 순수 coordinator이고, C2는 parent-fd에 결속된 fixed temp full-write→atomic rename 어댑터다. `test-workspace-checkpoint-file-adapter`의 Debug·ReleaseFast 8개 runtime+1개 layering gate가 전 syscall fail-index와 partial write, stale temp/symlink 회수, exact `0600`, rename 직전/직후 실제 child `SIGKILL`에서 이전 또는 새 완전본만 남음을 검증한다. C3는 committed mutation을 app-global owner에 모아 main-thread 전체 Window capture와 serial C2 background publish에 배선한다. C4는 final generation commit 전 AppKit 종료를 보류하고 실패 시 Quit 취소·mutation 재개·이전 완전본 보존, restore-incomplete의 secure create-once `.bak`을 배선한다. 실제 ad-hoc signed AppKit gate는 final checkpoint 성공·정상 종료와 저장 실패 Quit 취소·이전 완전본 보존을 자동 검증한다. provisioned Developer ID artifact 검증은 아직 미완료다. `zig build macos-session-host-r2a-checkpoint-smoke`의 정상 제품 launch·checkpoint armed 뒤 원본 byte 불변·SIGKILL 후 불변, R2a full/bare binding matrix·exact-cap/cap+1·allocator failure·null-session/deferred-session ABI rejection·Swift backup/write source order, R2b strict inventory request/page parser·canonical ordering·cap/cap+1·generation overflow/ABA·handoff round-trip·reconcile allocation/cap와 malformed semantic response 격리, CR6a-2 actual daemon/manifest/inventory와 CR6b actual click/검색 Enter, bounded fresh host/runtime evidence, orphan/ended success 및 stale generation/manifest slot/missing runtime mutation-zero 행을 포함한다. 별도 수동 real-AppKit 검증은 실제 `.app`을 2회 실행해 primary typed sidebar 표시를 관측했지만 자동 gate로 세지 않는다. 2026-08-25에는 opt-in 새 탭의 GUI 종료 뒤 host·shell PID와 exact runtime handle·socket 생존, 새 GUI의 동일 shell PID 재접속·계속 증가한 tick, 실제 한글 입력과 선택 복사/붙여넣기를 사용자 화면 및 process/manifest 대조로 확인했다. 이는 actual-app 수동 증거이며 자동·signed-runner gate를 대체하지 않는다. row action/adopt와 fresh authority revalidation은 CR6b gate로 자동 검증한다. L0는 secure leaf/typed ABI/source-order unit과 `mise run macos-app-instance-lease-smoke`의 실제 제품 direct double-launch, loser exit 2, winner 생존, `SIGKILL` 뒤 successor 재획득으로 검증한다. **P4 전체 종료 gate는 링크된 P4 절이 단일 출처**다. 대표적으로 topology/checkpoint+Quit 취소/slow-GUI 격리/100-runtime perf/parity/config explicit override retention, `A runtime→B exact adapter attach와 B host spawn→A drain` 또는 same-PID migration, GUI 0 notification exact click을 구조화 artifact로 검증한다. T0a는 connection 32 cap/generation ABA, resident queue와 global control reserve, turn fairness, partial absolute/progress deadline, upgrade admission/drain, allocator rollback을 검증한다. T0b0은 두 connection의 동일 local stream 1과 distinct global subscription, controller/observer 권한 격리, close revoke, 256/8,192 cap, counter overflow와 allocator rollback을 검증한다. T0b1은 prepare→admission→commit/rollback, subscription별 pressure invalidation 1회, sticky resync ACK, metadata+snapshot atomic recovery, draining 완료 전 valid 금지, split batch와 16/18 MiB exact cap을 Debug·ReleaseFast `test-session-host`로 검증한다. T0b2a는 runtime 256개와 aggregate 4,194,304 cells exact/cap+1, resize prepare→backend→commit, 부분 backend 실패 runtime fail-stop, spawn 전 preflight, terminate/natural-exit/restore rollback ledger 반환을 같은 gate로 검증한다. T0b2b는 forked canonical GUI+ephemeral inventory, 32+1 overflow throttle와 기존 연결 생존, parser-resident 65-frame drain, partial/blocked sibling 격리, cadence epoch 보존, slot hole 재사용, accept OOM rollback, typed preclosed same-PID exec→restore를 Debug/ReleaseFast 기본 gate로 검증한다. T0b2c는 explicit terminate와 natural exit의 두-client process fixture, metadata/snapshot/delta RuntimeNotFound, resync 우선 종료, sibling 보존, idempotent close, typed ended surface 전이와 OOM fail-close tracker/queue/subscription 회수를 같은 gate로 검증한다. P5a~P5c와 P5d의 ad-hoc 제품 경로는 runtime count/aggregate grid exact-cap 및 반환, local stream 1 충돌 방지, stable connection ABA, fairness/cap, upgrade drain race, 실제 PTY/localhost SSH attach·SIGWINCH까지 구현·검증됐다. P5d 전체 완료는 provisioned Developer ID artifact에서 같은 SSH gate를 재검증하기 전에는 주장하지 않는다. signed product-path와 실제 입력기/Notification Center는 provisioned logged-in macOS runner 없이 unit fixture로 대체해 완료 처리하지 않는다. |
| ↳ 영속 host IME legacy 호환 | 구현(실제 구 binary 재접속 gate 잔여) | 같은 MRSH v2의 구 host를 재사용할 때 `screen_viewport_scrolled_v1` 부재를 전면 미지원으로 보지 않는다. legacy visible cursor snapshot만 live bottom의 단방향 증거로 사용해 client-local preedit/candidate anchor를 허용하고, hidden sentinel은 scrollback과 DECTCEM-hidden live가 모호하므로 차단한다. 증거는 snapshot마다 재계산해 latch하지 않으며 동기 scroll RPC fallback은 없다. | 구 host에는 `ambiguous_wide` bit가 없어 한글/CJK 고정 wide는 표시하지만 ambiguous-width parity는 보장하지 않는다. 실제 구 binary 재접속과 AppKit 자모별 pixel은 아직 수동 gate다. | `test-session-host`가 legacy visible 성공, hidden `{0,0,false}` 차단, visible→hidden non-latch, current-host hidden-live 무회귀를 검증한다. 실제 구 binary host를 종료하지 않은 앱 업데이트→재접속 E2E는 후속이다. |
| ↳ 영속 host 선택 복사·업데이트 호환 | 같은-major 복사 호환 구현, N-1 adapter/major별 side-by-side seam 구현 중 | 최신 host는 `runtime_selected_text_v1`을 협상해 host `TerminalCore.extractSelection`을 SSOT로 쓴다. 앱보다 먼저 떠 있던 같은-major 구 host는 모르는 RPC를 호출하지 않고 실제 `RemoteScreen` viewport projection에서 복사한다. current와 capability-tagged N-1은 별도 MRSH connection·exact screen codec으로 연결하고 major별 endpoint를 쓴다. 장기 업데이트 정책의 최종 discovery 권위는 exact `host_id`별 build/epoch/lifecycle registry이며, capability 없는 기존 runtime은 자동 kill하거나 fresh shell로 위장하지 않는다. upgrade-capable하고 attachment가 0인 host만 same-PID exec migration을 시도하며, busy 또는 preflight 실패는 side-by-side로 돌아간다. disk metadata migration과 live runtime handoff state는 서로 다른 codec이다. | 구 screen wire에는 soft-wrap bit가 없어 구 host의 multi-row 선형 복사는 보이는 행마다 개행한다. 단일 행·block·wide/grapheme만 projection과 정확히 일치한다. 현재 major별 고정 endpoint와 N-1 adapter는 있으나 exact host manifest registry, 실제 frozen package, current+old AppSession/workspace E2E, 원인 notice, drain cleanup은 아직 없다. | `test-session-host`가 capability present host RPC, capability flag를 내린 실제 remote projection, MRSH/screen version 교차 거부, 다중 Window의 `AppSession.copyText` 경계, 단일 행·block·wide/grapheme 및 명시 multi-row 개행 정책을 자동 검증한다. 실제 frozen old binary의 socket handshake→reconnect→copy, old/current host 동시 세션 라우팅, legacy unversioned entry 등록, runtime 0 뒤 drain cleanup, 지원 밖 major notice와 무종료는 후속 gate다. |
| 설정 파일/설정 UI/runtime reload | 부분 구현 | config parser·schema·serializer와 메뉴의 수동 Reload Config/Reset to Defaults, 다수 runtime apply 경로가 구현됐다. 세부 GUI 진행 상태는 [세팅 페이지 전략](settings-page.md)이 단일 출처다. | 파일 변경 자동 감지와 남은 bespoke 설정 위젯, 일부 platform 시각 gate는 후속이다. | config round-trip/invalid fixture, runtime reload unit/app smoke를 유지하고 GUI 위젯과 Metal 시각 smoke를 단계별 추가한다. |
| Wasm plugin | 구현 전 | 현재 plugin registry는 no-op 구조다. | plugin boundary, 권한, event ABI, 실패 격리를 검증하지 못한다. | plugin hook API가 정해진 뒤 fixture plugin과 sandbox failure test를 추가한다. |
| 세션 컨트롤 플레인(CLI·웹뷰 IPC) | 부분 구현 (1a~1f L2/골격 + A1 Zig 측 collector + A2a CLI 실 소켓 연결 + **A2b 라이브 서버**(앱-전역 소켓+accept 스레드+메인 marshal+실 collector+최소 auth) + **browser 제어 라이브**(`maru browser` CLI ↔ `control_browser.dispatchBrowser` ↔ Swift BrowserControl — navigate/act/snapshot/console/screenshot/executeScript/wait/storage, §9.2 Model B 확인 모달·pane grant) — full self-origin(1g)·capability fd 실발급·capture 실 스크롤백/pump(1f 배선)·터미널 write(`sendKeys`)·`events.subscribe` 범용 이벤트는 미배선) | [세션 컨트롤 플레인](control-plane.md)이 wire(ndjson JSON-RPC), unix socket/웹뷰 브리지, `metadata:self` self-origin 증명, capability fd auth/scope, Phase 1~7 검증 전략, 각 Phase 시작 전 사용자 설명+이전 Phase regression gate, CLI `--help` 갱신 계약을 정의한다. 2026-06-29 local spike로 read-only fd+`pread`, non-login zsh/bash/sh fd 보존, 현재 macOS login wrapper fd close, zsh startup fd close, background fd persistence, tmux/screen pane fd close를 확인했다. **구현됨(테스트 커버)**: 1a 프로토콜(`control_plane.zig` — ndjson `Framer`·JSON-RPC 2.0 `Message`·`ErrorCode` -32001/-32002/-32003·hello)·1b 소켓 부트스트랩(`control_socket.zig` — bind/chmod/flock-stale/peer-cred/hello + client↔server 소켓 왕복 통합 테스트)·1c Surface DTO(`control_surface.zig` — `SurfaceDto`·at_prompt 3상 nullable-bool·`getSurface` §8.3 균일 unauthorized·scope 응답 직렬화)·1d dispatch+CLI(`control_dispatch.zig` 바이트→바이트 라우터, `cli/sessions.zig` 파서·`--help` 스냅샷·client wire; **1f 반영**: `session.capture`를 인식해 metadata 라우터에선 read-output 미충족 §8.3 균일 unauthorized로 접음)·**1e capability fd 인가 코어**(`control_capability.zig` — `hash(nonce)→cap store` constant-time lookup·scope↔method 매핑·fd payload magic/version·write/lifecycle 상속 fd 발급 금지·read-output TTL 필수·revoke)·**1f capture 프로토콜 코어**(`control_capture.zig` — chunk 스트림 상태머신 `Capture`(chunked=경계마다 generation 대조/atomic=pinned 스냅샷)·seq 오름차순·**base64**(비-UTF8·ESC·NUL 무손실 왕복)·빈 스크롤백 즉시 complete·**capture-invalidated**(chunk 경계 generation 불일치 시 완료 마커 금지, torn-read 방어)·**revoke 종료**(§8.5 보안 우선)·재시도 상한 fallback(`strategyForAttempt`/`RetryCoordinator`: 상한 초과→atomic이 generation 무시하고 완료해 무한 재시도 방지)·`dispatchCaptureAck` authz 게이트(주입 read-output → ack {capture_id,generation,scrollback} / 미인가 §8.3 균일 unauthorized·oracle 없음); **generation=스크롤백 evict/rewrap 카운터**(§4.3 — surface 재생성 §3 아님); 헤드리스 15 테스트, 실 스크롤백·실 read-output auth·L4 pump 미배선)·**A2a CLI 실 소켓 연결 + per-connection serve 함수**(`control_socket.zig` `serveReadOnly` — `readInto`+`Framer`→`dispatchReadOnly`→응답+`\n` 동기 1연결; `main.runSessionRequest` — 결정론 경로 `<cache>/maru/control` 발견→`std.c.connect`→`buildRequestBytes`→hello skip→`Framer`→`renderResponse`, 서버 부재면 graceful "인스턴스 없음"·exit 1·트레이스 없음; `cli/sessions.controlDir`/`pickSocket` 순수 발견 정책; 왕복은 tmpDir Server+`serveReadOnly`+실 client wire 헤드리스 테스트로 검증)·**A1 Zig 측 per-session collector**(`app_session.zig` `collectSessionInto`/`collectSession` — 실 AppSession의 tabs→panes→terms를 `SurfaceDto[]`+`WindowMembershipSnapshot`으로 평탄화, 좌표·focused·cwd·git_branch·agent·at_prompt 3상, `core_mutex` 아래 복사만; 실 AppSession controlled_smoke 하니스로 단일/다중 term·pane·tab·agent 유무·at_prompt 3상·window_focused 엣지 + **멀티창 merge**(두 세션 공유 리스트→하나의 스냅샷·key 창만 focused) 검증, 순수 매핑은 헤드리스)·**A2b 라이브 서버**(`control_server.zig` — 앱-전역 소켓+accept 스레드가 요청을 메인 frame loop로 marshal(§8.8 lock-order 준수), `ControlRequestQueue`/`PendingRequest` rendezvous; `app_host_abi.zig` start/drain/stop ABI + `collectSessionsInto`(Swift가 넘긴 창+quick을 창마다 collect) + 최소 auth(peer-cred same-uid + `auth.self` 셀렉터=MARU_PANE_ID → `metadata:self`); 헤드리스: 큐 FIFO/close-cancel·pending rendezvous·**전체 왕복**(client auth+요청→accept 스레드→메인 drain(fake snapshot)→응답, self scope 필터) macOS-gated 테스트 + ABI layout; **라이브 실측**: 비-smoke 앱이 소켓 bind → `maru sessions list`가 셀렉터(MARU_PANE_ID) 있는 팬의 진짜 세션(cwd·git·focused·at_prompt)을 반환하고, 셀렉터 없는 외부 shell 에도 **전체 목록**을 반환(2026-08-29 — 앵커를 안 댄 연결의 metadata scope 는 `all`, [보안 §8.4](control-plane-security.md)), macos-app-smoke가 start→drain→stop 수명 무크래시 확인). **견고성(적대적 리뷰 반영, 테스트 커버)**: start마다 다른 인스턴스 crash 잔해를 flock으로 회수(`pruneStaleSockets` — `.multiple` 발견 고장 방지; stale/self/live/고아 prune 단위 테스트), accepted 연결 read+write 타임아웃(`SO_RCVTIMEO`/`SO_SNDTIMEO` getsockopt 왕복 테스트 — 무한 블록·Cmd+Q 프리즈 방지), `readFrame` oversize→`payload_too_large(-32001)` 응답(socketpair 왕복 테스트 — 조용한 abandon 금지), `pollReady` 3상(`ready`/`timeout`/`broken`)으로 listen fd broken 시 tight-spin 대신 accept 루프 종료(분기 단위 테스트), `has_pending` 값싼 게이트(빈=false/push=true 큐 테스트 — 렌더 핫패스 0-할당). **tracked follow-up(#6/#8, 범위 밖)**: `ControlRequestQueue`는 serial accept라 in-flight≤1이지만(단일 슬롯이면 충분) 검증된 `PtyEventQueue` 스레딩 패턴을 의도적으로 재사용한다 — `PtyEventQueue`를 generic `BoundedQueue(T)`로 일반화해 두 큐를 통합하는 것은 별도 작업으로 남긴다(작동·검증된 스레딩 코드 재작성 리스크 회피). | A2b로 서버 소켓 배선(accept-loop 스레드↔메인 marshal §5)·Swift 멀티창 열거·실 collector·최소 auth가 붙어 `maru sessions list`가 진짜 세션을 반환한다. 아직 없는 것: **full self-origin 제품 경로**(1g — peer pid의 tty/foreground pgrp ↔ surface PTY 일치 검증. **A2b auth 한계**: 이게 없어 same-uid peer면 임의 surface_id를 `metadata:self`로 주장해 그 한 surface의 metadata를 열람 가능 — §8.4), **capability fd 실발급/상속**(1e — auth resolve 배선[1e-core]과 pane grant는 완료), `write`/`sendKeys`/`subscribeOutput`/`capture` 제품 배선(2·3), 범용 `events.subscribe`(browser 전용 `browser.subscribe`만 라이브), JSON-RPC trace schema. (web/browser 제어는 배선 완료 — 위 상태 칸.) A2a serve 함수·client 연결은 `control_socket.zig` 왕복 테스트 + 로컬 소켓 서버 스모크로 검증됨. **CI 갭**: `control_socket` 테스트는 macOS-gated라 ubuntu `check` CI가 안 돌린다(macOS 호스트 `zig build test`서 실행, Linux-host 검증 후 un-gate 후속). 특히 `capture`/`subscribeOutput`은 비밀 노출 경로라 capability fd 누락·잘못된 surface/generation·revocation 거부 테스트 없이는 열면 안 된다. 현재 login wrapper는 env는 보존하지만 fd를 닫으므로 일반 login shell에 `read-output` fd grant를 붙이면 안 된다. `metadata:self`도 `$MARU_SESSION`만으로 열면 안 되고, peer pid의 controlling tty/foreground pgrp가 selector의 PTY surface와 맞는지 제품 경로로 실측해야 한다. sudo/su는 로컬 noninteractive 검증이 불가해 controlled gate가 필요하다. 각 Phase 시작 PR이 이전 Phase 종료 gate를 다시 검증하지 않거나, 새 CLI 명령의 parser와 `--help` fixture를 함께 갱신하지 않으면 계획 완료로 보지 않는다. | Phase 시작 gate: 사용자에게 이번 Phase scope/파일 후보/새 capability·transport·의존성/자동·수동 gate/미결정 항목을 먼저 설명하고, 직전 완료 Phase의 종료 gate 또는 동등 regression gate를 재실행해 PR 본문에 남긴다. CLI-visible 명령은 같은 PR에서 parser와 `--help`를 갱신하고, help가 구현된 명령만 노출하는지 fixture/snapshot으로 검증한다. Phase 1: protocol/ndjson/max-frame unit, `SurfaceIdAllocator` 단조·비재사용·opaque ID, fake DTO 직렬화, `WindowMembershipSnapshot`, 2-window+quick 전역 ID 비충돌, `metadata:self` 응답 필터(self 하나만), `metadata:window`/`metadata:all` scope 필터, peer-cred 거부, self-origin auth 정상/변조 selector/다른 surface_id·generation·quick 교차 접근/외부 shell 복사 selector 거부, primary 창 2개+quick terminal 제품 실측 artifact(`tests/artifacts/control-plane/self-origin.summary.txt`), capability fd auth 정상/실패/invalid payload, read-only fd·`pread` 재호출, CLI fd close/`FD_CLOEXEC` 후 helper 누수 방지, CLI `--help` fixture(`sessions list`/`session get`/`session capture`), login wrapper 실패+non-login trusted profile 성공 smoke, zsh startup fd-close 실패, background fd persistence+TTL/revocation, tmux/screen pane fd-close 및 self-origin 결과 기록, dispatch·chunk 경계 revocation, `metadata`/`read-output` 허용·거부, `capture-invalidated` generation mismatch, `$MARU_SESSION`·nonce redaction. Phase 2~3: PTY write 통합, `send-text`/`send-keys`/`events subscribe`/`subscribe-output` help fixture, `subscribeOutput` backpressure/drop, background event source. trace 기록을 붙이는 PR은 먼저 [Trace와 Replay](trace-replay.md)와 [Facade 계약](facade-contracts.md)의 `Trace/Event` schema를 `control.*` event로 갱신한다. |
| 웹 패널(WKWebView 합성·브리지) | 구현(Phase 4~7 + browser 제어), 환경 의존 | [웹 패널 인프라](web-panel.md)가 WKWebView subview, Metal overlay, per-pane rect/surface diff ABI, 입력 responder 재편, web 보안(CSP/sanitizer/path sandbox)을 정의한다. **현재 상태**: 인앱 브라우저 패널·마크다운/파일 뷰어(`web/src` CM6 웹앱)·창간 WKWebView 재부모화·팝업 adopt가 제품 경로에 있고, `browser.*` 제어(navigate·act·snapshot·console·screenshot·executeScript·wait·storage)가 컨트롤 플레인으로 배선됐다(§9.5 — 아래 개별 행이 각 표면의 gate를 가진다). 웹 콘텐츠 단위 테스트는 `bun test`(`web:test`), 번들 품질은 `web:check`, 실 WKWebView 경로는 `macos-browser-bounded-smoke`·`macos-mermaid-perf`가 맡는다. 2026-06 spike(z-order·isolated world 격리)는 이 구현의 출발점이었다. 웹 콘텐츠 단위 테스트는 Phase 7부터 Bun 내장 test runner(`bun test`, `web:test`)를 기본으로 쓴다. Phase 4 착수 전 renderer preflight로 `mise run test`, `mise run check-boundaries`, CoreText/Metal smoke 계약 테스트와 display 가능 시 실제 CoreText/Metal smoke를 재실행해 자연폭/2-quad/role gate/atlas sampling이 기존 green인지 확인한다. | 입력/firstResponder, 실제 셀 모달 합성, drag hit-test 통과, per-pane 좌표계, markdown sanitizer, CEF 대안은 아직 검증되지 않았다. z-order 픽셀 합성은 CI 자동화가 어려워 GUI 골든이 필요하다. renderer preflight는 WKWebView 합성 자체를 증명하지 않고, 시작 전 렌더 계약 회귀만 잡는다. | Phase 4: rect px↔pt/y-flip unit, surface diff lifecycle unit, renderer preflight(`test`/`check-boundaries`/`test-macos-coretext-smoke`/`test-macos-metal-smoke`; display 가능 시 `macos-coretext-smoke`/`macos-metal-smoke`), NSView frame/계층 단언, input responder/manual E2E, drag pass-through 수동. Phase 5: `evaluateJavaScript` 브리지 주입/미주입, `frameInfo.isMainFrame`/origin 검사, CSP, path traversal/symlink 거부. Phase 7: Bun `web:test`로 웹 콘텐츠 JS/TS 순수 로직과 markdown sanitizer adversarial fixture(`<script>`, `on*`, `javascript:`, iframe/srcdoc, 외부 리소스)를 고정하고, WebDriver 어댑터가 없으면 `evaluateJavaScript` 하니스로 WKWebView E2E를 먼저 닫는다. Phase 6 WebDriver 뒤에는 같은 명령 subset을 표준 WebDriver smoke로 추가한다. Phase 4 종료 시 GUI 골든 1 frame을 artifact로 남긴다. |
| 에디터 surface | **부분 구현(엔진·스택은 출하), 제품 gate는 MergeView만 RED** | [에디터 Surface 전략](editor-surface.md)의 2026-07-16 PoC 결과에 더해, 2026-07-31 코드 대조로 **전제 세 가지가 이미 해소**됐다 — ⑴ CM6는 file-panel 소스 모드로 제품 WKWebView에서 출하 중이고(텍스트·caret·편집·한글 IME 통과), ⑵ 그 CM6가 **현행 엄격 CSP(`style-src 'self'`)에서 동작**한다(StyleModule 대신 정적 `app.css`, CM6 코어는 CSSOM `insertRule` 경로), ⑶ zntc pin은 `0.1.4`로 올라 CM6가 번들된다. PoC가 확인한 revision/CAS 모델·directory watcher·formatter config 실행 위험·atomic helper의 mode/symlink 파괴는 그대로 유효하다. | 임시 PoC는 저장소에 재현 하니스가 없다. **`@codemirror/merge`(MergeView)는 번들·WebKit·CSP 어느 것도 확인된 적이 없다.** editor grant/bridge, app-global single-writer DocumentRegistry, descriptor-relative safe-save, encoding/newline, dirty close/recovery, watcher, stable diff snapshot, git worktree/conflict, tool trust, LSP는 미구현이다. **도크 소스 컨트롤 뷰**(editor-surface §3.5)는 설계만 있고 도크에 뷰 스위처 자체가 없다. socket 1 MiB와 markdown bridge 8 KiB 때문에 전체 before/after blob API도 허용할 수 없다. | E0.5A(범위 축소): MergeView 렌더·chunk 마커·accept/reject와 **현행 CSP 위반 수 계측**, 1/2/4 diff 파일 Term 자원 회수를 artifact로 고정한다(편집 경로는 출하 검증으로 대체). E0.5B: versioned bridge, grant/path/CAS/encoding/safe-save/watcher/recovery 순수 계약. E1: 도크 뷰 스위처 + 소스 컨트롤 뷰 chrome + diff kind 파일 Term + bounded `diff.list`/`diff.open`. 이후에만 저장·선택적 tool execution·LSP를 순서대로 연다. pixel parity는 필수 oracle이 아니며 semantic oracle과 제품 WebKit gate를 분리한다. |
| 에이전트 훅 통합(provider 훅 수신·모드) | **AH1~AH7 완료**(게이트 `sidebar.agent-hooks` **기본 `true`** — 2026-08-22 전환, 설정 GUI 로 끌 수 있다. AH7 = host-backed 터미널의 훅 모드) | [에이전트 훅 통합](agent-hooks.md)이 계약을, [단계 계획](plans/agent-hooks.md)이 AH1~AH6을 소유한다. **두 모드를 섞지 않는다** — 훅이 설치된 Term은 상태·알림·턴을 훅 payload에서만 얻고, 그 Term에서는 OSC 9/777 알림과 `agent_observer`의 화면·OSC title/progress·`output_active` 입력을 쓰지 않는다(OSC 7/133/52/11 등 무관 시퀀스와 `agent_kind` 판정용 프로세스 관측은 그대로 돈다). 훅이 없으면 [agent-session.md](agent-session.md)의 관측 모드가 그대로 돈다(그 문서는 2026-08-20 개정으로 관측 모드 전용). 이벤트 세트는 provider 마다 다르다 — claude **9개**(`SessionStart`·`UserPromptSubmit`·`Stop`·`StopFailure`·`Notification`·`PermissionRequest(*)`·`PreToolUse(*)`·`SubagentStart`·`SubagentStop`), codex **7개**(`Notification`·`StopFailure` 가 없다 — 2026-08-21 codex 자신의 `hooks/list` 로 확정). codex 에는 `PostToolUse`·`SessionEnd`·`PreCompact` 도 있으나 우리가 안 건다. Codex `trusted_hash` 가 훅 내용을 따라 바뀌므로 세트를 늘리면 **사용자에게 재승인을 다시 요구한다**(이번 확장이 그렇다).  Codex `trusted_hash`가 훅 내용을 따라 바뀌므로 **한 번에 확정**해야 한다(그 해시의 **입력은 실측으로 재현하지 못했다** — 계약 §2.1). `PostToolUse`는 `originalFile`을 실어 큰 파일 편집에서 상한에 잘리므로 **뺐다**(계약 §3.1). **구현**: [`session/agent_hook_command.zig`](../src/session/agent_hook_command.zig)(인라인 커맨드·표식·legacy 식별·타임아웃)와 [`session/agent_hook_event.zig`](../src/session/agent_hook_event.zig)(ndjson 파서·tail 커서·재동기화·Codex 패치 경로). 실제 셸 게이트 `zig build check-agent-hook-command`가 계약 **11개**를 돌린다(상한을 넘긴 payload 에서 **이름만 살리는** 계약이 아홉 번째, **host 소유 신원**(`host_<hex>`/32 hex runtime)이 같은 커맨드로 도착하는지가 열한 번째다 — 5d). **AH2a**: 설치 판정·트리 수술은 [`session/agent_hook_install.zig`](../src/session/agent_hook_install.zig)(순수 — 상태→계획, `hooks` 배열에서 우리 표식만 골라 빼고 세트대로 다시 넣는다), 파일 세계(락·CAS·atomic write·로그 디렉터리 `0700`)는 `app_session/agent.zig`의 `reconcileAgentHooks`이고, **시작 시 로그 정리**(소비자가 없어 자라기만 하는 것을 막는다 — 게이트와 무관하게 돈다)는 같은 파일의 `cleanupAgentHookLogs`. 게이트는 `sidebar.agent-hooks`(**기본 `true`** — 2026-08-22 전환). 선결이던 셋이 다 닫혔다: 비용 실측, 양 provider 대화형 확인, 설정 GUI 노출. ⚠️ 켜면 사용자의 provider 설정 파일을 고치고(끄면 우리 표식만 거둔다), **codex 오류 턴은 확정된 한계**이므로(2026-08-22 공개 소스, 2026-08-25 실측) 그때 배지가 안 풀리면 이 키를 끄는 것이 즉시 회피책이다. **실측(2026-08-21 재측정 — AH6)**: 훅 1회 10.39 ms(`sh` spawn 기저 10.05 ms, 7 판 × 300 회를 **번갈아** 재고 중앙값). **샌드박스 안팎에 차이가 없고**(기저 10.19 ms, 판 사이 변동 폭 안) 스크립트 몫은 +0.34 ms 로 **측정 한계(±0.64) 아래**다 — 남는 레버는 발화 횟수뿐이다(도구 없는 턴 2~3 · 도구 턴 3~6 · 서브에이전트 턴 9 · 관측된 큰 턴 36). 옛 판의 12.27 ms 는 `cat` 으로 stdin 을 비우던 시절 값이고 지금 커맨드는 셸 내장 `read` 라 그 몫이 없다. payload는 개행 없는 한 줄 JSON, Claude와 Codex의 `PreToolUse.tool_input` 모양이 다름(Codex는 `command` 하나뿐, 경로는 패치 텍스트 안), 셸 편집은 양쪽 다 훅에 안 잡힘, 동시 append 인터리브는 간헐적(24개 동시 쓰기에서 회차마다 0~2줄). | **claude 는 대화형 검증을 마쳤다(2026-08-22)** — 헤드리스에서는 `PermissionRequest` 도 `Notification` 도 오지 않지만(권한 거부를 실제로 유발해도), 승인 프롬프트가 뜨는 실제 세션에서는 `PreToolUse → PermissionRequest → Notification(permission_prompt)` 이 **셋 다 같은 `prompt_id` 로** 오고 **배지가 「입력 대기」로 서는 것을 눈으로 확인했다**. 한 승인에 두 소스가 다 발화하지만 전이가 하나뿐이라 알림도 하나다(전이에 붙인 설계가 여기서 값을 한다). 그 payload 가 코드로만 세웠던 전제를 전부 확인했다 — `Notification` 은 키 일곱뿐이고 `tool_name`·`tool_input`·`agent_id` 가 **없으며** `message`·`prompt_id` 를 싣는다. 🔴 **그 확인이 최대 결함을 드러냈다 — 훅 모드에 «들어갈» 수 없었다.** 모드 판정의 유일한 동적 입력(`log_present`)을 세우는 곳이 `pollAgentHookEvents` 뿐인데 그 함수는 이미 훅 모드일 때만 불렸다 — 판정이 자기 입력을 잠갔다. 게이트를 켜도 새 Term 은 영영 화면 관측이었고, **첫 «입력 대기» 확인도 훅이 아니라 관측이 그린 것**이었다. 진단은 사용자의 관찰이다 — 「승인 프롬프트에서 선택을 2번으로 옮기면 배지가 바뀐다」(훅은 «선택을 옮겼다» 를 안 보내므로 그 움직임 자체가 화면을 읽는다는 증거). 판정과 입력 갱신을 갈라 고쳤고, 재확인에서 배지가 화면을 안 따라가고 대화 줄이 payload 로 채워지는 것을 확인했다. ⚠️ **테스트가 못 잡은 이유가 이 세션의 반복 패턴이다** — 제품 테스트가 `pollAgentHookEvents` 를 **직접** 부른 뒤 분기를 확인해 「들어가는」 경로를 한 번도 안 봤다(테스트가 결과를 보는 자리와 실제 경로가 다른 것). 지금은 그 경로만 겨누는 테스트가 있다. ✅ **codex 도 확인했다** — `Notification` 이 없어 그 배지의 소스가 `PermissionRequest` 하나뿐인데, `codex -a on-request -s read-only` 로 파일 쓰기를 시키면 `PreToolUse(apply_patch)` 에 이어 그것이 실제로 온다. payload 가 계약의 다른 서술도 확인했다(`tool_input` 은 `command` 하나뿐·`turn_id` 있음·`model` 은 codex 에만). ✅ **codex 오류 턴도 종결했다(2026-08-22)** — 「미검증」이 아니라 **확정된 한계**다. `codex exec` 에 없는 모델을 줘 400 을 만들면 `SessionStart` → `UserPromptSubmit` 뒤 아무것도 안 오고, 공개 소스가 그것이 `exec` 특유가 아님을 못 박는다 — `core/src/session/turn.rs` 의 오류 경로가 `run_turn_stop_hooks` 를 부르기 **전에** 반환하고(공용 턴 기계라 대화형도 같다), 그 사실은 훅이 아니라 extension API(`turn_lifecycle_contributors`)로만 나간다. 결과: 오류로 끝난 codex 턴은 배지를 «진행 중» 에 남기고 다음 턴이 정상 종료할 때 풀린다. `SessionEnd` 로도 못 메운다(세션이 끝날 때만 온다). ✅ **재측정으로 「세트를 늘려도 못 닫는다」까지 확정했다(2026-08-25, codex-cli 0.149.0)** — 우리가 구독하지 않는 셋(`PostToolUse`·`PreCompact`·`SessionEnd`)까지 함께 걸고 같은 400 을 냈는데, 정상 턴은 `SessionStart`→`UserPromptSubmit`→**`Stop`**→`SessionEnd` 인 반면 오류 턴은 `SessionStart`→`UserPromptSubmit`→**(없음)**→`SessionEnd` 다(그 `SessionEnd` 는 양쪽 다 프로세스가 끝날 때 오는 마지막 한 번이라 턴 경계가 아니다). 그때까지 이 대목은 **설계 추론**이었다. 부수 확인 둘: `StopFailure` 는 codex 이벤트가 아니고(11 개를 걸었는데 신뢰 항목이 10 개만 생겼다), `postCompact` 는 **걸지 않았다**(턴 경계가 아니라 제외 — 「전부 걸었다」고 적지 않기 위해 밝힌다). 재현은 격리 `CODEX_HOME` 에 이벤트마다 이름을 적는 훅을 깔고 **그 홈에서만** 승인한 뒤 정상 턴을 대조군으로 먼저 돌리는 것이다(승인이 없으면 훅이 조용히 안 돌아 「오류 턴에 아무것도 안 온다」와 구분되지 않는다). 회피책은 `sidebar.agent-hooks` 를 꺼서 그 Term 을 관측 모드로 되돌리는 것이고, 닫으려면 codex 가 그 경로에 훅을 내어 주어야 한다. **codex 에는 `Notification` 이벤트가 아예 없다**(2026-08-21 실측) — 완료(`Stop`) 알림은 codex 에서도 정상이고, 못 받는 것은 claude 가 `Notification` 으로 주는 「입력 대기」 계기다. **codex 에는 `StopFailure` 도 없고**, 오류로 끝난 codex 턴이 `Stop` 을 **안 보내는 것**이 2026-08-25 실측으로 확정됐다 — 그 pane 의 배지가 안 풀린다. `background_tasks` 는 claude 전용 키라 codex 에서는 그 축을 애초에 못 받는다(손해도 오작동도 없다). 훅 모드에서는 **임의 프로그램의 OSC 알림도 사라진다**(발신자 구분 불가 — 감수하는 손해, 되찾으려면 훅을 끈다). MCP·커스텀 도구가 고친 파일은 `tool_input` 스키마가 제각각이라 소행 확정에서 빠진다(tree 비교가 잡으므로 유실은 아님). | **훅 경로의 신원을 소유자별로 갈랐다(③-1, 2026-08-24)**: pane 칸이 control-plane selector `MARU_PANE_ID` 를 그대로 쓰던 동안은 host-backed 터미널에 훅 신원을 실을 방법이 **계약에 없었다**(그 값은 GUI process-local surface id 라 재실행 뒤 남의 pane 을 가리킨다). 훅 경로가 자기 변수(`MARU_HOOK_PANE`)를 갖고, 두 칸의 모양이 소유자별로 정해졌다 — GUI 는 `pid`/`surface_id`, host 는 `host_<32 hex host_id>`/`<32 hex runtime_id>`. host 칸이 pid 가 아닌 이유는 업그레이드가 **프로세스를 바꿔도 host_id 를 물려주기** 때문이다(pid 로 지으면 업그레이드 뒤 살아 있는 runtime 의 로그를 정리가 거둔다). 만드는 곳은 계약 모듈 하나(`format*` 넷)이고, 셸 가드의 문자 클래스와 maru 쪽 판정이 **한 상수**(`TokenClass`)에서 나온다. ⚠️ **그 클래스를 넓히자 로케일 함정이 드러났다** — 셸 bracket 의 범위(`a-z`)는 collation 을 따라 en_US.UTF-8·ko_KR.UTF-8 에서 **대문자를 통과시킨다**(C 는 거부). 훅은 `LC_ALL` 을 정할 수 없어 표기를 낱글자로 펼쳐 막았고, 5d 는 **넉넉한 로케일에서도** 돌린다. 옛 `[!0-9]` 는 글자가 없어 이 함정 밖이었다 — 셸 게이트가 머지 전에 잡았다(뮤테이션 4개로 게이트 자신도 확인). 남은 것은 host 쪽 배선이다(host 가 자기 `host_id`·`runtime_id` 로 두 칸을 채우기 — `runtime_id` 가 지금 spawn **뒤에** 발급되므로 그 순서도 바꿔야 한다). 그 전까지 `persistentSpawnRequest` 가 두 칸을 떼어 fail-closed 다. **로그 위생(완료 2026-08-21)**: 크기 상한 1 MiB 회전(rename → 커서 리셋 → 회전본 tail 건지기 → 삭제)과 종료 시 «소유 pane» 정리. 제품 경로가 1 MiB 를 실제로 채워 **회전 뒤에도 마지막 이벤트가 남는지**, 새 파일을 처음부터 읽는지, 회전 도중 죽어 남은 회전본을 거두는지 본다. ⚠️ **동시 기록 경합**(우리가 읽은 뒤 rename 전까지 훅이 덧쓰는 창)은 단일 프로세스로 못 만들어 자동 검증이 없다. **AH1(완료)**: 부분 라인·회전 경계·오프셋 전진·상한 절단·손상 라인 무시·형 변화 방어·재동기화 상한(뮤테이션 검증)·세트↔파서 드리프트(뮤테이션 검증)·구분자 comptime 가드(뮤테이션 검증)·상한 경계·빈 `out` assert·provider 이름 검증 = 단위 40개, 실제 셸 계약 11개(append 형식·**로그 파일 0600**(넉넉한 umask에서 확인)·가드 경로·stdin 드레인·상한 접기(이름 보존·미지 이름)·디렉터리 부재 조용함·pane 칸 경로 탈출·인스턴스 칸 경로 탈출·**host 소유 신원 왕복**·동시 append 유실 0). **AH2a(완료)**: 순수 층 21개(빈 설정 설치·바이트 멱등·사용자 항목 순서 보존·빈 껍데기 미잔류·낡은 커맨드 재설치·matcher/timeout 드리프트·세트 밖 항목 회수·legacy 불간섭·모르는 모양이면 판정 포기 — 여섯 뮤테이션으로 확인), 제품 경로 무인 게이트 `zig build **codex 신뢰 값이 낡으면 알린다(2026-08-25).** codex 는 `config.toml` 의 값이 그 훅의 현재 내용과 다르면 그 훅을 **실행하지 않는다**(`hooks/list` 의 `trustStatus` 가 `modified`, TUI 는 "hooks won't run"). 키는 항목의 **자리**로 만들어져 커맨드를 고쳐도 그대로라, 커맨드가 바뀐 뒤에는 「키는 있고 값만 낡은」 상태가 남는다 — 실제로 2026-08-24 커맨드 변경 뒤 이 저장소 개발 환경의 V3 훅 7 개가 전부 그랬고 배지가 조용히 화면 관측으로 떨어져 있었다. **어긋난 값은 제자리에서 갈아 끼우고**(덧붙이면 같은 테이블이 둘이 되어 codex 가 `config.toml` 전체를 못 읽는다), 「우리 값이 틀렸을 때 무한 프롬프트」는 **시도를 값 하나당 한 번으로 묶어** 막는다 — 써 넣은 값을 표식 줄에 `tried=` 로 남기고, 그 기록이 지금 쓰려는 값과 같으면 이미 써 봤고 누군가 되돌린 것이므로 다시 쓰지 않고 **알린다**(고치는 법까지 문장에 싣는다 — codex 를 한 번 실행해 "Trust all and continue"). 고친 것도 알리되 둘이 겹치면 **못 고친 쪽을 먼저** 보여 준다. 값을 못 읽으면 세지도 고치지도 않는다(거짓 경고·남의 값 훼손 금지). 순수 층은 `agent_hook_trust.storedHash` 가 소유하고, 제품 경로는 `test-provider-session-removal` 의 「codex 신뢰 값이 낡으면 한 번만 고치고, 되돌아오면 알린다」가 한 세션에서 **고침 → 되돌아옴 → 안 고침**을 순서대로 태운다: 갱신 뒤 파일이 설치본과 **바이트가 같고**(제자리 수술이 줄 하나만 갈고 나머지는 원문 그대로), 값이 되돌아오면 **파일 무변경**(= 무한 루프가 아니다), 그리고 tick 이 실제로 부르는 경로(`runFramePreHousekeeping`)로 알림이 뜨고 카운터가 비워진다. **«고쳤다» 는 파일에 실제로 들어간 뒤에야 세운다** — CAS 가 다른 인스턴스에 밀리거나 쓰기가 실패하면 하지 않은 일을 했다고 말하게 되고, 그때 사용자는 할 일(승인)도 못 듣는다. 그래서 쓰기 전에는 고치려던 것까지 «어긋남» 으로 센다. 그 분기는 「codex 신뢰 값을 못 썼으면 «고쳤다» 고 말하지 않는다」가 **디렉터리를 읽기 전용으로 만들어** 실제로 태운다(CAS 경쟁은 단일 프로세스로 못 만들지만 같은 분기다). **「되돌아온 값」은 «안 돈다» 가 아니라 «갈렸다» 로 센다** — 우리가 쓴 직후 누군가 다른 값을 넣었다는 뜻이고 그 누군가가 승인받은 codex 면 훅은 정상으로 돈다(그때 「승인하라」는 방금 승인한 사람에게 하는 거짓말이다). 그래서 카운터와 문구를 가르고, 판정자가 **어느 문구가 떴는지까지** 본다(개수만 세면 옛 문구로도 통과한다). 이 자리가 **프로세스 없이 드리프트를 잡는 유일한 지점**이기도 하다. ⚠️ codex 만 바뀌고 우리 커맨드가 그대로면 「파일의 값 == 우리 계산」이라 조용히 통과한다 — 자기 계산으로 자기를 검증하는 한 구조적으로 못 본다. 뮤테이션 8 개(안 세기·세고 안 알리기·tick 배선 끊기·수를 latch·차단기 제거·값 줄 안 바꿈·쓰기 전에 「고쳤다」·되돌아온 값을 «안 돈다» 로 세기)로 확인했다. test-provider-session-removal`이 `AppSession.init`을 실제로 돌려 확인(사용자 항목이 우리 것보다 앞·과거 표식 잔존·로그 디렉터리 `0700`(이미 있던 `0755`도 좁힌다)·**지난 실행 로그 정리와 남의 파일 보존**(확장자·숫자 stem 두 가드를 각각 물게 하는 픽스처)·재실행 시 바이트 무변경·**게이트 off면 `hooks` 키 무생성**, 일곱 뮤테이션으로 확인). **AH2b-1·2(완료)**: 세트를 provider 별로 가르고(codex 7 개 — `Notification`·`StopFailure` 없음, 분리가 실제로 판정을 바꾸는지 대조 테스트로 확인하되 기대치는 두 세트에서 comptime 으로 **유도**한다 — 손으로 적으면 세트가 바뀔 때마다 그 숫자를 고치게 되고 테스트가 «분리가 판정을 바꾼다» 대신 «내가 최근에 무엇을 더했나» 를 재게 된다), codex 신뢰 값 계산을 순수 층으로 세웠다(`agent_hook_trust.zig` — app-server `hooks/list` 로 받은 **codex 자신의 해시** 를 세트 전원 golden 으로 박고 뮤테이션 6 개로 확인. matcher 를 해시에 넣는지도 codex 가 답했다 — `user_prompt_submit`·`stop` 만 뺀다). **AH2b-3·4(완료)**: `hooks.json` 설치와 `config.toml` 신뢰 기록을 배선하고 제품 경로 게이트로 확인했다(codex 세트대로 설치·과거 표식 잔존·사용자 항목이 앞·**신뢰 키가 실체 경로**(심링크 `CODEX_HOME` 픽스처)·재실행 바이트 무변경·새 `config.toml` `0600`, 뮤테이션 6개). **제거(완료)**: 게이트를 끄면 같은 경로를 `Intent.uninstall` 로 타 우리 표식 항목과 codex 신뢰 블록을 거두고, 남는 것이 없으면 `config.toml` 을 파일째 지운다 — 제품 경로가 «켰다 → 껐다» 를 실제로 돌려 확인한다(다른 최상위 키·사용자 훅·과거 표식·**사용자가 직접 승인한 신뢰 항목**이 모두 살아남는지, 두 번 꺼도 무동작인지. 뮤테이션 4개). ⚠️ `config.toml` CAS 는 **단일 프로세스 테스트로 재현 불가**(동시성) — 코드 리뷰로만 확인했다, statusLine 훅 제거 후 세션 신원 유지. **AH3(순수 층 완료)**: `agent_hook_mode.zig` — 모드 판정은 **로그 파일 유무**(이벤트 개수로 잡으면 가만히 있는 세션이, 시간으로 잡으면 이미 돌던 세션이 잘못 강등된다), 전이는 `Stop` 의 재발화·background_tasks 예외 포함, 배지 상태는 관측 모드 열거를 **공유**(타입 동일성 테스트로 고정), 파서 `Kind` 전수 분류 가드. 단위 31개·뮤테이션 6개. **platform 배선도 완료**: `pollAgentHookEvents` 가 로그를 tail 파싱해 상태와 마지막 대화를 채우고, 소비자 분기가 모드로 갈려 훅 모드에서는 화면 관측을 **아예 부르지 않는다**(OSC 알림도 버리되 pending 은 비운다). 제품 경로 게이트가 실제 `AppSession` + 실제 로그 파일로 확인한다(파일 없으면 관측·생기면 훅·커서 전진·**inode 회전**·새 프롬프트가 옛 응답을 지우는 것, 뮤테이션 5개). **AH5(알림 소비)도 완료**: 알림을 상태 전이에 붙여 중복 방지를 구조로 얻고(같은 턴 재알림·재발화 `Stop`·백그라운드 잔여가 모두 전이를 만들지 않는다), 주의 알림은 디바운스해 자동 해소를 버린다. 방출은 관측 모드와 같은 tail 이라 위치 접두·히스토리·전면 억제가 한 벌로 유지된다(뮤테이션 5개). ⚠️ 남은 것은 **대화형 수동 검증** — `PermissionRequest` 는 헤드리스로 발화하지 않아 실제 승인 프롬프트가 뜨는 세션에서 입력 대기 전이와 주의 알림을 눈으로 봐야 한다. **오판 고치기(완료 2026-08-21)**: 배지가 «거짓말하는» 세 부류를 닫았다 — ⑴ `StopFailure`(오류로 끝난 턴에 `Stop` 이 안 온다), ⑵ `background_tasks` 를 «비었나» 가 아니라 «`status`가 `running`인 것이 있나» 로 세는 것(끝난 항목 하나가 배지를 영원히 붙잡는다), ⑶ 서브에이전트를 `SubagentStart`/`SubagentStop` 으로 **세는 것**(자식이 도는 동안 lead `Stop` 은 턴 끝이 아니고, 마지막 자식이 끝날 때 푼다 — 세지 않고 «떴다» 표시만 들면 자식의 `Stop` 이 `agent_id` 때문에 무시돼 배지가 영영 안 풀린다. 그 설계를 한 번 짰다가 되돌렸다). **진행 중 세부**도 함께 섰다 — `PreToolUse` 의 `tool_input.description`(없으면 `tool_name`)을 사이드바 running 줄에 `"▁▅▇▃ 진행중 · <세부>"` 로 싣는다(세부가 없으면 예전과 **바이트가 같다**). 순수 규칙 뮤테이션 4개 + 제품 경로 뮤테이션 6개로 확인했고, `max_events` 와 «세트 밖» 기대치는 세트에서 comptime 유도해 다시 어긋나지 않게 했다(손으로 적은 `8` 이 claude 9개에서 실제로 범위를 넘겨 터졌다). **훅 게이트를 켜면 턴 스냅샷이 사라지고 있었다**(문서-코드 대조가 잡았다) — 관측 모드는 `pollAgentState` 가 턴 끝에 `captureTurnSnapshot` 을 부르는데 훅 모드는 그 함수를 아예 안 부른다(§1.3 배타). 계약 §1 표가 훅 모드의 턴 경계를 `UserPromptSubmit`/`Stop` 이라 적어 두었는데 그 배선이 없어, **게이트를 켠 것만으로 «에이전트가 방금 바꾼 것» 이 통째로 사라졌다.** 같은 술어(`isTurnEnd`)를 훅 전이에 태우고, 자식이 남아 lead 를 붙잡은 동안에는 안 찍게 했다(그때 찍으면 자식이 고칠 파일이 스냅샷 뒤에 바뀌어 빠진다). 저장소가 없으면 그 함수가 조용히 돌아가므로 결과가 아니라 **호출 자체**를 세는 테스트 카운터로 확인한다. **오류 알림 문구도 갈랐다**(적대적 검증 2차가 잡았다) — `Stop` 과 `StopFailure` 가 같은 전이를 만들어 오류로 끊긴 턴이 «턴이 끝났습니다» 로 나가고 있었다. 자식이 남으면 끝 전이가 마지막 `SubagentStop` 에서 일어나 그 사실이 사라지므로 진행 상태가 들고 가고, 알림을 꺼낼 때 지운다(안 지우면 다음 턴의 정상 종료가 «오류» 로 나간다). 관측 모드로 돌아갈 때 자식 셈을 안 버리던 갭도 같은 검증에서 나왔다. **유령 자식을 `background_tasks` 로 거둔다**(2026-08-21) — 붙잡는 근거가 «시작을 봤다» 라 그 종료를 못 보면 배지가 영영 안 풀린다. `type: "subagent"` 항목의 `id` 가 수명 이벤트의 `agent_id` 와 정확히 같다는 실측(앞서 「다르다」고 적었던 것은 대조 없는 단정이었고 그 사례는 `type: "shell"` 이었다)에서 «도는 목록에 없으면 끝났다» 를 유도했다. 규율 셋으로 안전하게 만든다: **lead 의 턴 끝에서만**(자식이 막 떴을 때 거두면 산 것을 지운다), **목록이 완전할 때만**(잘림·어긋남·키 부재는 근거가 아니다), 그리고 **거두는 쪽으로만**(`SubagentStop` 이 그 자식을 아직 `running` 으로 실어 오므로 «running 이면 붙잡는다» 는 영영 안 풀린다). 뮤테이션 4개(완전성 무시·시점 확대·목록 무시·회수 삭제)로 확인했다. **codex 실사용에서 `__oversized__` 가 실제로 발생했다**(2026-08-21) — 32 KiB 를 넘긴 payload 가 통째로 버려졌다. `Stop` 이 그러면 턴 끝을 잃어 배지가 안 풀리므로, 버리기 전에 **이름만 살리도록** 커맨드를 고쳤다(셸 내장 `case`, 모르는 이름은 예전처럼 표식). 실제 셸 게이트가 그 계약을 본다(9 개로 늘었다). 그 과정에서 **골든 픽스처의 신선도 검사가 조용히 낡는** 것도 드러났다 — 표식·상한 두 앵커가 로직 변경을 못 봐서, 세트의 이벤트 이름 전부를 세 번째 앵커로 더했다. **실사용 한 번이 자동 검증 아홉 회차가 못 잡은 결함을 잡았다**(2026-08-21) — 서브에이전트를 «개수로 세는» 설계가 틀렸다. claude 는 우리가 시작을 본 적 없는 내부 에이전트의 `SubagentStop` 도 보내므로(한 턴에서 `SubagentStart` 1 개 대 서로 다른 id 의 `SubagentStop` 5 개, 우리 것의 짝은 맨 마지막), 개수를 세면 **자식이 도는 중에 배지가 풀린다**. `agent_id` 집합으로 바꾸고 그 실측 순서를 회귀 테스트로 박았다. `background_tasks` 는 마지막 자식 종료까지 «도는 중» 이라 해제 근거로 쓸 수 없다(쓰면 영영 안 풀린다). 같은 세션이 **세션 시작 시 «턴이 끝났습니다» 알림**(`unknown → idle` 을 턴 끝으로 읽던 것)도 드러냈다. **세트를 늘린 뒤 codex 신뢰도 E2E 로 확인했다**(2026-08-21) — 골든 해시는 «codex 가 계산한 값» 이지 «우리가 쓴 파일을 codex 가 신뢰한다» 가 아니다. 제품과 **같은 함수·같은 순서**로 격리 홈에 설치한 뒤 `hooks/list` 로 물어 **7개 전부 `trustStatus=trusted`** 를 받았다(새 `subagent_start`·`subagent_stop` 포함). 틀렸다면 사용자가 매 실행 승인 프롬프트를 봤을 것이다. **실측 줄을 제품 경로에 그대로 태우는 테스트도 뒀다** — 지금까지 제품 테스트의 입력은 전부 손으로 쓴 JSON 이라 «내가 생각한 키» 만 덮었다. 진짜 줄에는 `effort`·`tool_use_id`·`session_crons`·`agent_type`·`agent_transcript_path`·`permission_mode` 처럼 안 써 본 키가 있고 키 순서도 다르다(경로만 가리고 나머지는 한 글자도 안 고쳤다). 실측 43줄을 파서에 먹여 **파싱 실패 0**도 확인했다. 그 재생이 **내 단언 하나를 깼다** — lead 자신의 응답이 자식의 말을 인용해서("서브에이전트가 `echo from-child`를 실행했고…") «자식 응답을 안 쓴다»를 부분문자열로 물으면 틀린다. 합성 입력이었다면 영영 안 걸렸을 함정이다. **턴 식별자도 쓴다**(claude `prompt_id`·codex `turn_id`) — 리셋 신호가 `UserPromptSubmit` 하나뿐이면 그 줄이 유실될 때 지난 턴의 자식 셈이 넘어와 배지가 안 풀린다. ⚠️ 자식 이벤트의 키는 보지 않는다(codex 자식은 **자기 turn_id** 를 쓴다 — 실측). ⚠️ **눈으로 본 확인은 아직이다** — 실제 서브에이전트를 띄우는 대화형 세션에서 배지가 자식이 끝날 때 풀리는지, 세부 문구가 사이드바 폭에서 읽히는지. AH4: 상태 전이표, 조용히 오래 도는 셸 명령에서 진행중 유지, `AskUserQuestion`이 `PreToolUse`로만 올 때 입력 대기 + **대화형 수동 검증**. AH5: 같은 턴 중복 0, 자동 해소 승인에서 배너 0·배지 1, 포커스 억제 + **대화형 수동 검증**. **AH6 완료**(2026-08-21 재측정): 훅 1회 10.39 ms · spawn 기저 10.05 ms(7 판 × 300 회, 변종을 **번갈아** 재고 중앙값 — 한 판씩 재고 빼면 판 사이 변동이 효과보다 커서 **훅이 기저보다 «빠르게» 나온다**. 그 함정을 두 번 밟았다). **샌드박스 안팎 차이 없음**(기저 10.19 ms, 변동 폭 안)이라 옛 「절대값은 상한」 단서는 삭제했다. 스크립트 몫은 +0.34 ms 로 **측정 한계(±0.64) 아래** — 「최적화 여지가 없다」가 더 단단해졌고 레버는 발화 횟수뿐이다. 턴당 발화도 실측 로그에서 셌다: 도구 없는 턴 2~3 · 도구 턴 3~6 · **서브에이전트 턴 9** · 관측된 큰 턴 **36**(~0.36초, 다만 그 턴은 모델 왕복이 이미 수십 초다). 지금 수치로는 `PreToolUse` 를 좁히는 후퇴가 필요 없다. **`Notification` 으로 「입력 대기」를 판정한다(완료 2026-08-21)**: 「입력 대기」의 다른 소스인 `PermissionRequest` 가 **어떤 측정에서도 발화하지 않아** 그 배지에 소스가 없을 위험이 있었다. claude 바이너리의 `notification_type` enum(열넷)을 읽어 «사용자 입력을 기다린다» 는 다섯만 배지를 옮기고 나머지·모르는 종류는 «모르는 이벤트» 와 같이 상태를 안 흔들게 했다 — 그래서 임의의 provider 알림이 「입력 대기」로 보이지 않는다. 순수 층 뮤테이션 3개(모르는 종류도 옮김·아는 종류를 안 옮김·유휴 알림을 목록에 넣음)와 제품 경로 하나(승인 payload → `blocked` + 주의 알림, 유휴 payload → 무동작)로 확인했다. 자식이 보낸 알림이 부모 배지를 안 옮기는 것도 함께 박았다. ⚠️ **«실제로 온다» 는 여전히 대화형 수동 검증이다** — 헤드리스에서는 `Notification` 도 안 온다. **적대적 검증이 그 위에서 결함 둘을 더 잡았다(2026-08-22)**: ⑴ **주의 알림의 본문이 비어 있었다** — `Notification` payload 에는 `tool_name` 도 `tool_input` 도 없는데(생성부 대조) 승인 경로의 본문 규칙을 그대로 써서 «떴는데 아무 말도 안 하는» 알림이 됐다. 제품 경로 단언을 «종류만» 에서 «본문까지» 로 넓혀 실패를 먼저 보이고 고쳤다(그 테스트의 주석은 「무엇을 승인해야 하는지도 함께 온다」고 적어 놓고 그것을 **단언하지 않고 있었다**). `message` 는 대화 줄(`text`)이 아니라 **다른 자리**에 담는다 — 섞으면 뒷날 어느 provider 가 그 이벤트에 `message` 를 더할 때 대화 줄이 조용히 오염된다. ⑵ **자식이 남은 뒤 온 알림이 턴을 되살려 배지가 영영 안 풀렸다** — claude 의 알림은 공통 payload 를 **에이전트 인자 없이** 만들어 `worker_permission_prompt` 도 `agent_id` 가 빈 채 lead 로 온다(`PermissionRequest` 는 그 인자를 넘겨 자식 것이 자식으로 온다). lead 가 이미 `Stop` 을 보낸 뒤 그것이 `turn_open` 을 켜면 마지막 자식이 끝나도 «턴이 안 끝났다» 가 된다. 그래서 알림은 상태만 옮기고 턴 문은 건드리지 않는다. **전수 탐색이 이 가지를 한 번도 안 밟고 있었다** — 알파벳의 알림이 `notification_type` 없는 것뿐이라 배지를 옮기는 조합을 만들지 못했다. 알파벳을 22 기호로 넓히고 「알림은 턴 문을 안 건드린다」를 깊이 3 전수 불변식으로 박았다. **2차 적대적 검증이 둘을 더 잡았다**: ⑶ **지난 턴의 알림이 늦게 오면 이번 턴의 자식 셈이 지워졌다** — 알림도 공통 payload 를 타고 `prompt_id` 를 실어서 «턴이 바뀌었다» 로 읽혔다(자식 1 → 0, 그러면 lead 의 `Stop` 이 자식을 안 기다린다). ⑷ **자식이 뜨면 «입력 대기» 가 지워졌다** — `SubagentStart` 가 무조건 «돈다» 를 돌려줘, 병렬 워커 턴에서 하나가 승인 게이트에 걸린 채 다른 하나가 뜨면 **사용자가 할 일이 있다는 신호만 골라 사라졌다**. 관측 모드의 `visible_blocker` 최우선 규율에 맞췄다. ⚠️ ⑷는 `Notification` 이전부터 `PermissionRequest` 경로에 있던 결함이고 그것이 발화하지 않아 안 보였을 뿐이다(전수 탐색이 `{session_start, session_start, permission_request}` 로 짚었다). ⑵⑶이 같은 규칙의 두 자리라 조건을 손으로 되풀이하지 않고 **`marksTurnProgress` 한 이름으로 묶었다** — 흩어 두면 다음에 자리를 더할 때 잊는다(실제로 잊어서 둘 다 나왔다). 뮤테이션 7개로 확인. **근거를 공개 자료로 올렸다(2026-08-22)**: claude 는 [hooks 스펙](https://code.claude.com/docs/en/hooks)이 `Notification` payload 를 `message`·`title`·`notification_type` 으로, `StopFailure.error` 를 «error **type**» 으로 적어 위 ⑴과 실측(`error="authentication_failed"` 대 `last_assistant_message="Not logged in · Please run /login"`)을 함께 뒷받침한다. ⚠️ **다만 `notification_type` 값 목록이 스펙(9개)과 제품(14개)에서 어긋난다** — 스펙에만 `elicitation_complete`·`elicitation_response`, 제품에만 `worker_permission_prompt` 외 여섯. 그래서 블랙리스트로 짜면 어느 한쪽에서 틀리고, 화이트리스트+「모르면 안 옮긴다」만이 두 목록 모두에 대해 성립한다(스펙에만 있는 두 이름도 테스트에 박았다). codex 는 **공개 소스가 권위다** — `HookEventName` 열거가 이벤트 열하나를 정의하고(`Notification`·`StopFailure` 없음, `SubagentStart`/`Stop` 있음 — 우리 7개가 실재), `hooks/src/schema.rs` 가 `deny_unknown_fields` 로 payload 를 못 박아 `turn_id` 있음·**`background_tasks` 없음**(claude 전용)·`model` 은 codex 에만·`SubagentStop.agent_id` 는 비옵션임을 직접 말한다. 그 대조가 **문서 오류 하나를 잡았다** — 「codex 에 있지만 우리가 안 거는 것」이 셋이 아니라 넷이다(`post_compact` 누락, 설치본 0.149.0 에도 실재). |
| 에이전트 턴 변경분(훅 경계·AI 소행·영속성) | 설계 확정, 미구현 — P5 턴 타임라인 위에 얹는 넷 | [에이전트 턴 변경분](agent-turn-changes.md)이 계약을, [단계 계획](plans/agent-turn-changes.md)이 AT1~AT6 순서를 소유한다. 아래 층(턴 경계의 의미·임시 index 스냅샷·링 8개·화면 소유)은 [editor-surface-tooling.md §6.1](editor-surface-tooling.md)과 [§3.5.4](editor-surface-dock.md)가 이미 소유하고 [P5](plans/scm-dock.md)(2026-08-18)로 구현됐다. 훅 payload는 **양 provider 실측**으로 확인했다 — Claude는 훅 임시 설치 + `claude -p` 1회로 `SessionStart`/`Stop`/`PostToolUse`(Edit `structuredPatch`·`originalFile`)를, Codex는 격리 `CODEX_HOME` + `codex exec --dangerously-bypass-hook-trust`로 `SessionStart`/`UserPromptSubmit`(`turn_id`·`prompt`)을 받았다. 셸 편집이 provider 기록에 남지 않는 것도 실측했다(Bash `tool_response`={stdout,stderr,interrupted,isImage,noOutputExpected}, `~/.claude/file-history/` 백업 미생성). 커밋 0회·스테이징 0회로 tree 스냅샷 두 개 사이 diff가 성립함을 재실증했다. | 턴 경계가 화면 관측(`running → idle`) 단독이라 전이를 한 번 놓치면 두 턴이 하나로 합쳐지고 사후 복구가 불가하다. 링이 메모리·창 로컬이고 스냅샷 tree는 참조가 없어 `git gc` 대상이라 재시작 뒤 복원조차 못 한다. AI 소행과 사용자 편집이 같은 목록에 섞인다. 셸 편집 비중이 큰데(실측 Bash 3403 : Edit 12) 그 사실이 화면에 없다. **Codex `PostToolUse` payload는 미검증**이다 — 실측 중 provider 사용량 한도로 모델 호출이 실패했다. 2차 검토(코드 대조)로 둘이 더 드러났다: 훅 payload를 나르는 **전달 채널이 없다**(현행 `agent-sessions/<id>`는 `cat >` 덮어쓰기라 한 tick 안의 앞 이벤트가 사라지고, 소비 경로는 claude 전용 + 세션 id 문자열만 인정한다), ref 고정의 **`<owner-key>`가 미정**이다(링은 창당 하나인데 ref 이름 공간은 저장소 공유이고, 현행 창 키는 재시작하면 달라지는 포인터다). 한계의 단일 출처는 계약 §8이고 이 칸은 그 요약이다. | AT1: 훅 스크립트 문자열 골든, 설치·제거·재설치 멱등성, 훅과 관측 두 트리거가 같은 링으로 수렴(같은 tree 중복 push 억제). AT3: synthetic·redacted JSONL fixture로 양 provider의 add/update/delete/rename·손상 라인 무시·저장소 밖 절대경로·빈 턴. AT4: `✎`/`·`/`↩` 3분류 분기, git 아닌 디렉터리에서 `✎` 목록만으로 서는지, 필터 기본 off. AT5: ref 생성·회전·삭제와 `git gc --prune=now` 후 tree 생존(임시 저장소 통합), 워크스페이스 간 ref 격리. 수동: 계약 §2.5 격리 홈 절차(설정 원복·`auth.json`은 심볼릭)를 provider 메이저 버전마다 1회. |
| browser.wait 동기화 | 환경 의존(실 WKWebView), 헤드리스 계약은 자동 | L2는 selector/load params·1..25000ms 상한·`-32004` timeout data·invalid selector/process-exited/unauthorized 상태 매핑·capability-vs-pane-grant provenance·target surface close/process-exited와 grant origin pane close/unauthorized 판정·CLI parse/wire+`--help` snapshot·hello capability 발견성을 자동 검증한다. L4는 `@MainActor` 100ms 직렬 polling, monotonic deadline, WebKit callback과 독립한 deadline task, 단일 완료 gate를 쓴다. macOS app smoke는 실 소켓→WKWebView에서 처음부터 hidden으로 존재한 요소가 첫 poll 150ms 뒤 visible이 될 때만 성공, idle load 성공, 125ms deadline 뒤 visible이 되는 요소의 timeout, invalid CSS `-32602`를 기록한다. | CI의 헤드리스 테스트만으로 WebKit DOM layout box·`isLoading` 전이, surface close/grant revoke와 진행 중 callback의 실 GUI 경합을 완전히 증명할 수 없다. | `MARU_WEB_PANEL=1 MARU_TEST_BROWSER_CAP=1` macOS app smoke에서 `browser_ctl_wait_selector/load/timeout/invalid_selector=true`와 selector elapsed 범위를 확인한다. surface close 및 pane grant revoke 중 wait 취소의 실제 GUI/socket 경합 smoke는 후속 추가한다. network-idle·URL/text/function·action auto-wait는 별도 slice다. |
| browser.console 캡처(§9.5.9) | 환경 의존(실 WKWebView), 헤드리스 계약은 자동 | L2는 `browser.console {id,clear?}` params·arg(`{clear}`)·result(`{console}` 구조화 embed·malformed→internal_error)·op_kind 17 assert·base `browser` scope·lifecycle·CLI parse/build/`[level] text` 렌더+`--help` snapshot을 자동 검증한다. L4는 page-world document-start override(`console.*`/onerror→bounded `window.__maruConsole`, **메시지 핸들러 0**=§8.1(c) 유지)→throttled(300ms) proactive drain→Swift 서버 버퍼(cap 500·네비 넘어 보존·lazy-enable=첫 pull)→pull 최종 drain 파이프라인을 쓴다. macOS app smoke는 실 소켓→WKWebView에서 `console.log`/`console.error` 발화 후 `browser.console` pull이 `[log]`/`[error]`를 회수하고 clear=true 뒤 재-pull이 비는지 기록한다. | CI 헤드리스만으로 실 WKWebView 주입 override·drain·네비 보존을 완전 증명할 수 없다. 페이지가 override를 삭제/위조 가능(자기 로그 숨김·비신뢰 등급)·args 구조화·worker/서브프레임 console·네트워크/pageError는 범위 밖(§9.5.9 한계). | `MARU_WEB_PANEL=1 MARU_TEST_BROWSER_CAP=1` macOS app smoke에서 `browser_ctl_console_capture=true`·`browser_ctl_console_clear=true`를 확인한다. |
| browser op close/revoke/timeout 수명 | 공통 헤드리스 상태머신 + Swift type-check | queue 기반 전 메서드의 lifecycle 분류·exact method→scope 표(`browser_storage` 포함)·bulk-only byte 예약은 exhaustive enum table로 고정한다. 대표 getCookies 경로가 queued authority loss=`-32002`, running target close=`-32003`, late/duplicate callback drop과 0-byte 예약을 검증하고, queued timeout 뒤 물리 entry·arg·capacity를 같은 tick에 회수해 max=1 queue가 즉시 재사용되는 회귀 테스트를 둔다. typed timeout/process-exited/unauthorized serializer는 navigate/getCookies/screenshot/setCookie/click 대표군으로 공통 분기를 고정한다. Swift host는 executeScript 외 screenshot/cookie/storage/act callback도 surface registry에 등록한다. navigation realm change와 일반 창·quick close·WebContent crash는 realm-bound callback만 synthetic backend terminal로 끝내고, cookie/clearStorage는 실제 data-store callback까지 slot을 유지함을 `macos-app-host-swift-check`가 type-check한다. | 이미 시작된 WebKit mutation은 rollback할 수 없다. 자연 TTL 만료와 deadline이 경합하면 첫 terminal이 이긴다. 실제 callback navigation/close/crash 경합과 전 메서드×원인 순열은 공통 함수의 대표 테스트로 커버하므로, 개별 WebKit API가 별도 수명 동작을 추가할 때 해당 메서드 사례를 확장해야 한다. | 사람 손 테스트는 필수가 아니다. 회귀 시 `mise run test`, `zig build test-macos-app-host-abi`, `zig build -Doptimize=ReleaseSafe macos-app-host-swift-check`를 실행하고, display가 있으면 bounded smoke로 실제 WKWebView 경로를 보조 확인한다. |
| browser.executeScript/screenshot 결과 pump | 5f-5c 기능 구현 완료(Track 5 성능 gate 별도) | Swift 단위 실행이 JavaScriptCore syntax-only 양면 검증으로 wrapper 탈출 payload를 거부하고 익명 function/class 표현식을 허용하며, eval 없는 async-thunk wrapper와 registry ID 비재사용·entry/aggregate cap·offset/copy 상한·idempotent release를 검증한다. Zig는 원 number lexeme 기반 `-0`·nonzero underflow·float-form unsafe integer와 `args` 128 허용/129 거부 경계, off-main validation 뒤 running+pending+인가 start gate, 512 KiB inline/초과 chunk validator, request/result/capture id·seq·bytes·PNG IHDR, connection 4 MiB/process 32 MiB queued+writer-owned 회계, terminal carve-out, abort purge, tick당 한 chunk/terminal, 중복 callback과 release-failure cancel, release·reservation 1회 반환, screenshot 공통 pump와 CLI atomic no-replace spool을 헤드리스로 고정한다. `mise run macos-browser-bounded-smoke`는 strict-CSP 실제 WKWebView/socket에서 expression+Promise await+args 성공, nested eval 차단, 고유 URL commit과 page-marker handshake 뒤 실행 중 navigation 분류, 정확히 512 KiB inline, 512 KiB+1 chunked 2개, 16 MiB chunked 32개 완료와 pump action>0·p95≤0.5ms·max≤1.0ms를 artifact로 검증한다. ABI v120 header/Zig/Swift type-check는 `mise run test-macos-app-host-abi`·`mise run macos-app-host-swift-check`가 확인한다. | GitHub 기본 CI는 Ubuntu라 Swift 실행/type-check와 실제 WKWebView smoke를 돌리지 않는다. app/WebContent RSS artifact와 bridge handoff/frame deadline 귀속은 별도 Track 5 성능 gate에 남아 있어 hello 16 MiB capability는 아직 열지 않는다. 공개 WebKit API가 개별 WKWebView의 WebContent PID를 제공하지 않으므로 별도 프로세스 귀속 방식은 시스템 전체 WebContent 합계가 아닌 재현 가능한 식별 계약이 필요하다. | GUI 눈검사는 필요 없다. macOS에서 `mise run macos-browser-bounded-smoke`를 실행한다. 자동 smoke가 실제 strict-CSP WKWebView, socket, 32 frame tick pump와 terminal을 모두 통과하므로 별도 사람 조작은 요구하지 않는다. |
| 파일 도크 닫기·트리 키보드·파일 변경 | 구현(ABI v126~v130) | L2/headless는 단일 entry close active-index 보정, 3-choice confirm, 포커스별 `close_focused`, path+row-kind tree selection과 전체 탐색 키를 고정한다. focused 선택 행은 theme accent 배경과 WCAG 4.5 이상 대비가 나는 단일 전경을 marker·이름·dirty/conflict 전체가 공유한다. 파일 변경은 이름/root/symlink/dirty-descendant 정책, create/rename atomic no-replace, bounded worker queue overflow/recovery, 지원 확장자 kind 전이와 지원→비지원 dock 제거를 검증한다. L4 AppSession 통합은 inline edit·F2·`⌘Backspace`, clean source-edit request-scoped read-only snapshot ack, mutation reservation 중 stale bridge 차단, tmpDir create→rename→비-dot staging과 주입된 not-moved rollback→moved-verified clean tab close→moved-unverified destination recovery 상태 전이를 검증한다. worker는 root/parent/source의 device·inode·kind를 descriptor-relative no-follow 경로에서 다시 대조하고 delete는 같은 parent의 예측 불가능한 visible sibling으로 atomic no-replace staging한다. ABI v129는 staged path/identity action과 `not_moved / moved_verified / moved_unverified { path? }` completion을 제공하고, v130은 `.dock_toggle` render role을 `NativeMetalCell.reserved=32`로 명시 전달한다. Swift는 공용 `fileTreeTrashIdentityMatches`로 staged/destination을 판정하고, 한 입력의 destination map과 destination identity가 모두 일치할 때만 verified success로 인정한다. | AppKit firstResponder, 실제 accent/dim 픽셀, 한글 marked-text lock 실패, 정상 Finder 휴지통 표시·복구는 제품 앱 확인이 필요하다. Swift destination-map→3-state 분류는 현재 type-check만 자동화되며 Zig 테스트는 outcome 주입 뒤 상태 전이만 검증한다. destination-map 누락·staged disappearance 조합은 일반 수동 조작으로 결정론적으로 재현할 수 없어 미검증 한계이며 후속 native adapter test가 필요하다. 공개 inode-conditional Trash/rename API가 없어 same-UID 프로세스의 마지막 precheck→syscall 경로 교체 공격은 명시적 위협 경계 밖이다. callback 미도착은 결과가 불명확하므로 자동 성공/재시도하지 않고 exit와 후속 mutation을 계속 차단한다. 도크 토글은 role 전파·normal 동일 PUA·visual-bottom 기하를 자동 검증하지만 Objective-C 최종 quad 픽셀 assertion은 아직 없어 제품 `MARU_SCREENSHOT` 캡처를 수동 gate로 유지한다. | 자동 gate: `mise run test`, `mise run check`, `mise run web:check`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-app-smoke`. 제품 앱 수동 gate: active/hover X, dirty 선택지, 포커스별 `⌘W`, `⌘⇧E`, 전체 tree key, F2, `⌘Backspace`, Finder 휴지통에서 비-dot 항목 표시·복구, 우상단 도크 토글 ink, WebView↔tree↔terminal firstResponder와 주소·CM6 입력 무회귀. |
| 파일 패널 FP16 워크스페이스 Term 전환·탐색기 전용 도크 | 구현(a~g 전부, 2026-07-27~28) | 계약은 [파일 패널](file-panel.md) §1~§8이 단일 출처이고, 이 행이 진행·검증 상태를 소유한다. **a 문서**(§1 결정 뒤집기 + cross-doc 정합) · **b 모델**(`Entry` 소유자를 `DockGroup`→`Term.file_entry`로, 창당 경로 유일성을 pane 트리 walk로, `== .browser` 판정 8곳을 `isBrowserTerm` 하나로 통합) · **c 수명**(`collectWebSurfaces`가 창 전 탭을 돌고 비활성 워크스페이스는 zero rect + hidden으로 남긴다) · **d chrome**(헤더 밴드를 파일 Term의 `ChromeInset.top`으로, browser 주소창 밴드와 같은 `paneBandRect` 경로) · **e 도크 축소**(`DockGroup`/`DockTree`/drop/`dock_drag.zig` 삭제 — `dock_panel.zig` 1581→316줄, 남은 `DockGroup` 문자열은 주석과 `normalizeEmptyDockGroups` 함수명뿐) · **f 영속**(`file-term` 키 + persisted 압축 인덱스 + 1회 마이그레이션) · **g rename 재설계**(`applyFileTreeRename`이 expected path + `mutation_pending_id` 스탬프로 검증, kind가 바뀌면 `rebuildFileTermSurface`). **`EntryId`/`EntryIdAllocator` 삭제는 의도적으로 철회**했다 — `.dock_pending { EntryId }` publish barrier가 그 축을 계속 쓴다(file-panel-dock-ui.md §3.4). | 렌더·firstResponder·워크스페이스 전환 시 미저장 편집 보존은 헤드리스로 증명되지 않아 GUI 확인에 의존한다. | 자동 게이트(`mise run test`·`check`·`web:check`·ABI·swift-check·`macos-app-smoke`) green + GUI 손 테스트 완료(2026-07-29 사용자 확인). |
| rich Button B1 및 pixel-aligned text | 구현(B1-text·B1-button-a/b + generic builder 3단계 완료 — `bf0cf6f5`·`7cb02395`·`ca0f127e`. 소비자는 Session Dock과 archive detail 둘이며 `activateFocused` host 배선은 후속) | Action label·registered SVG icon은 `TextPlacement`의 immutable `center-in-content`/`leading-icon-group` 정책으로 함께 worker artifact에 들어간다. worker가 CJK/fallback ellipsis 뒤 실제 label advance·line box와 SVG icon final-pixel placement를 만들고, main actor는 renderer record resolve와 cache-hit `shapeFromRecords`만 수행한다. button hit/action identity·disabled semantics는 같은 completed tree에 남는다. | headline typography 전체 이관과 B1-button-b의 system UI/Jetendard 1×/2× group-centre capture는 아직 PR gate로 남는다. | B1-role: `zig build test-chrome-ui`, `zig build test-macos-chrome-lab-smoke`, `zig build check-boundaries`. B1-button-b: semantic layout·synthetic SVG artifact unit, `mise run macos-agent-session-archive-smoke` AppKit/Metal capture, system UI/Jetendard 1×/2× PNG/JSON을 PR에 첨부한다. |
| 에이전트 세션 기록 도크 (Codex·Claude, AS4-f·AS5·AS6 현재) | 구현 — UI/상호작용·스캔·정렬 계약이 모두 이행됐다. 남은 것은 아래 한계의 수동/잔여 gate뿐이다 | AS4-f의 `DockMetrics`는 28pt right-dock safety band, Session Dock switcher, root/header/scope/search/group/card/detail/action/scroll metric을 하나의 snapshot으로 resolve한다. 검색은 `OverlayInput { query, preedit }`와 `InputFocus.agent_session_search`를 통해 click·`/`·macOS committed text·한글 IME marked/commit·candidate caret를 같은 owner로 묶고, preedit는 표시만 하며 commit 뒤에만 immutable snapshot의 in-memory filter를 갱신한다. AppSession integration test가 committed text/IME preedit가 terminal PTY로 새지 않는 것을 고정한다. header refresh idle/busy는 같은 24pt registered-SVG slot을 쓰므로 refresh click이 1-cell Unicode glyph로 축소되지 않는다. `SessionDockUiZoom`은 Cmd font-size 비율을 750–1500 milli로 clamp해 backing scale과 한 번 합성하고, 그 resolved scale을 layout·CoreText request/fingerprint·paint·hit-test·scroll projection에 함께 전달한다. actual AppKit fixture는 기본 zoom의 isolated cold process 네 개(terminal font 14pt/24pt × injected render scale 1×/2×)에서 실제 Swift→ABI→Zig published tree의 header, scope, search, first/expanded card, resume/reveal border rect를 JSON으로 관측한다. 같은 기본 zoom의 두 font rect는 exact equality, 2× raw rect는 1×의 두 배를 요구한다. 별도 `font-zoom` AppKit process는 실제 `MaruMetalTerminalView.keyDown`의 Cmd+= → Cmd+- → Cmd+-를 보내, 스크롤에 잘리지 않는 published scope-row rect가 확대 → baseline 복귀 → 축소되고 terminal identity가 유지되는지를 확인한다. Zig integration test는 clamp/reset 경계를 보완한다. | **AS5가 스캔 갭 넷을 닫았다(2026-08-08 실측).** streaming parser로 파일 크기와 무관한 고정 64 KiB 버퍼가 됐고(이전 피크 463 MB), 그 전제를 방어하던 read cap이 사라져 **목록이 라운드마다 337개로 같다**(이전에는 69→272로 늘며 12라운드에도 미완). `partial`이 DTO로 올라와 헤더가 불완전을 말하며, 도크 첫 진입에도 스캔 요청이 나간다. **AS6가 정렬 갭을 닫았다.** 정렬 키가 transcript의 마지막 활동 시각이고(못 읽은 파일만 mtime 폴백) 카드의 `N분 전`이 같은 값을 읽는다 — 이전에는 실측 362개 중 257개(70%)가 제자리가 아니었고 Claude 쪽 최대 차이가 144시간이었다. header에 최신순/오래된순 토글이 있으며 방향은 표시 계층에서만 바뀐다. 골든 case `header-utility-row`가 `로컬`·토글·refresh의 배치를 픽셀로 판정한다 — 그 전까지는 **어떤 골든도 헤더를 보지 않아** utility를 통째로 지워도 전부 통과했다. exact-live는 macOS POC의 argv-only child 관측 한계로 provider 공식 payload→pane-bound mapping 설계 승인 전까지 차단이다. 실제 사용자 Codex/Claude resume도 사용자 승인 수동 gate다. Session Dock 검색의 실제 firstResponder/한글 candidate 위치는 AppKit smoke에 아직 독립 scenario가 없어 수동 확인 항목이다. 정렬 토글의 실제 pointer 왕복과 2× backing scale의 header utility rect JSON도 같은 성격의 잔여 gate이며, 정렬 결과를 실제 이력으로 대조하는 것은 개인 데이터라 CI에 넣을 수 없다(로컬 40개 표본을 독립 구현과 대조해 나노초까지 일치를 확인했다). | `zig build test`, `mise run test-macos-app-host-abi`, `mise run macos-app-host-swift-check`, `mise run macos-agent-session-archive-smoke`, `git diff --check`. |
> **AS3-c 상태:** AS3-c1의 integer pixel projection, dock 전용 wheel residue, same-tree partial card clip과 `partial-scroll` Metal Lab artifact에 더해 AS3-c2의 exact `{provider, session_id, device, inode}` refresh/resize anchor와 PageUp/PageDown/Home/End를 구현했다. anchor가 없거나 materialize되지 않으면 path/mtime/이웃을 추측하지 않고 numeric offset만 새 상한에 clamp한다. `expanded-scroll-anchor` isolated AppKit process는 실제 precise `NSView.scrollWheel`, retained tree, mtime reorder refresh, 새 published generation의 raw-top 보존과 1920×960 전후 capture를 확인한다. 계약과 상세 gate는 [에이전트 세션 기록 도크](agent-session-list.md)가 단일 출처다.

> **AS4 snapshot-replace·scroll-anchor 정정(현재):** 위 표의 snapshot replacement stale race와 expanded-card scroll-anchor 잔여 표기는 과거 상태다. `snapshot-replace-pointer` isolated AppKit process가 ordinary refresh pointer, scan worker discovery gate, old ready `resume` pointer-down, same-directory atomic replacement, immutable snapshot publication, old rect pointer-up을 순서대로 실행한다. 교체된 exact identity의 detail capability는 materialize되지 않고, 늦은 up은 provider argv·external open·새 Term/active surface 변경을 만들지 않는다. `expanded-scroll-anchor`는 실제 `NSView.scrollWheel` gesture 뒤 다른 fixture record의 mtime reorder를 ordinary refresh에 결합하고, 같은 detail request의 unclipped raw card top이 publish 전 retained snapshot과 새 published generation의 replacement snapshot에서 유지되는지 확인한다. 기본 `SessionDockUiZoom=1000`의 terminal font 14pt/24pt × render scale 1×/2× dock/action rect JSON도 완료됐다. actual AppKit fixture가 published tree의 header/scope/search/first·expanded card/resume/reveal rect를 비교해 font family/line-spacing 독립성과 raw 2× 비례를 확인하고, physical `keyDown` `Cmd+=`/`Cmd+-` font-zoom fixture와 Zig integration test가 확대·축소·clamp/reset을 같은 resolved Dock scale에서 확인한다. exact-live만 표에 적힌 별도 한계다.

> **시각 골든 게이트(2026-08-05):** chrome/renderer의 시각 계약은 그동안 사람이 캡처를 **눈으로** 확인했고,
> 그 방식이 실제로 회귀를 놓쳤다 — 부분적으로 보이는 행이 "잘린" 것과 "세로로 눌린" 것을 구분하지 못해
> 클리핑이 죽은 상태를 정상으로 보고했다(#1882 코드리뷰가 잡았다). 이제 `macos-agent-session-archive-smoke`가
> 남긴 제품 lowering+Metal 오프스크린 PPM 캡처의 **관심 영역**을 커밋된 골든과 픽셀 비교한다(`test-dock-visual-golden`,
> CI macOS job). 전체 프레임(5.5 MB)이 아니라 계약이 걸린 좁은 사각형만 저장해, 무관한 UI 변경으로 갱신되지
> 않게 했다: 스크롤 클립 경계·확장 액션 라벨·목록 밀도 3장. 갱신은 `MARU_UPDATE_GOLDEN=1`(기존 replay 골든과
> 같은 관례)이며 **갱신 후 눈으로 확인하고 커밋**한다 — 자동 갱신은 회귀를 골든으로 굳힐 수 있다. 실효성은
> 골든 1픽셀을 손상시켜 확인했다(다른 픽셀 1개, 최대 채널 차이 128, 좌표까지 지목). 채널당 2 허용치는 러너
> rasterizer 미세 차이를 흡수하되 이 게이트가 잡으려는 결함(클리핑 실패·라벨 소실·밀도 변화)보다 훨씬 작다.
> **신뢰 범위(2026-08-06 이관 후)**: Lab은 제품 Session Dock과 **같은 두 텍스트 경로**를 탄다 — 아이콘은
> 셀 draw list(`buildIconTextDrawList`), 라벨은 `system_text.Artifact`, 스크롤 clip은 published tree의
> `content` 사각형. 그래서 레이아웃·구조뿐 아니라 **텍스트 정렬과 텍스트 클리핑까지** 골든으로 고정한다
> (`group-pill-clipped-edge` — 스크롤 상단에 걸린 pill의 잘린 변이 직선인지). 이관 전에는 Lab이
> `chrome_draw_lowering.RichTextArtifact`(셀 격자 + 오프셋, clip 없음)를 써서 그 case를 넣었다가 제거해야
> 했다. 이관 실효성은 clip을 끄고 재캡처해 확인했다(`partial-scroll-cards` 1460픽셀,
> `group-pill-clipped-edge` 71픽셀 차이로 실패). pane 합성의 **세로 축은 2026-08-24에 닫혔다**
> (`dock-over-status-bar` — 도크 뷰포트를 상태바 높이만큼 줄이고 그 아래 under 층에 띠를 심는다.
> 골든 둘: 도크가 그 뷰포트 안에서 끝나는가, 스크롤된 목록의 잘린 첫 행이 위쪽 고정 chrome 을
> 침범하지 않는가). **아래쪽 clip 은 이 축으로 잴 수 없다** — 목록이 가상화라 뷰포트 아래로 넘치는
> 행을 만들지 않아, clip 을 꺼도 그 아래는 안 변한다(적대적 검증 2026-08-25). 남는 간극은 **가로
> 축**이다(터미널 pane 과의 오프셋·레이어 순서) — Lab 의 텍스트 경로가 pane 원점을 못 받는다.
> ⚠️ 한계: 캡처가 없으면 skip한다(스모크를 안 돌린 환경/플랫폼). 그리고 골든은 **관심 영역만** 보므로 그
> 사각형 밖 회귀는 여전히 못 잡는다 — 새 시각 계약을 만들 때 case를 함께 추가해야 한다.

> **스크롤·클리핑 회귀(2026-08-05):** 사용자 보고(스크롤/새로고침 플리커, 글자가 카드 밖으로 샘, 액션이 빈 상자)의
> 루트커즈는 layout이었다 — scroll-area가 `fill` container라 목록 아이템이 viewport에 맞춰 균등 축소되고 있었고,
> 가상화가 마지막 아이템을 항상 viewport 밖으로 두므로 그 축소가 상시 상태였다(실측 112/256/48 → 83/190/35).
> published rect가 `DockMetrics`와 갈라져 scroll projection·텍스트 offset·action label line box가 모두 어긋났다.
> 아이템을 shrink 대상에서 빼고, 셰이핑 캐시 키를 스크롤 평행이동에 불변으로 만들고(캐시 miss 프레임은 measured
> 텍스트를 하나도 안 그리므로 스크롤 내내 글자가 사라졌다), 클리핑을 emit 시점 all-or-nothing 판정에서 backend의
> 픽셀 연산으로 옮겼다. `/code-review high` 6건과 그 뒤 적대적 검증 3건을 remediation했다(캐시가 submit이 아닌
> poll 시점 원점을 저장, `renormalizeGpuGlyphUvs`가 클립 UV를 덮어써 부분 행이 찌그러짐, 음수 origin 드롭이
> 스크롤 불변 키와 만나 영구 빈 줄, chevron이 legacy cell 경로라 clip 미적용, 잘린 pill의 radius/border, errdefer
> 누락, 슬롯 반올림이 이웃 텍셀 침범, 셰이핑 키와 request의 필터 갈라짐). 도크 typography는 같은 화면 터미널
> 글자보다 커 보인다는 보고로 두 단계 낮췄다. 자동 gate는 `zig build test`(142)와
> `mise run macos-agent-session-archive-smoke`의 실제 AppKit+Metal PPM 캡처이며, 캡처 전후 비교로 빈 버튼·잘림·
> 밀도를 확인했다. ⚠️ 남은 한계: 부분 클립의 atlas 슬롯이 정수 픽셀이라 1px 미만 반올림 오차가 있다(후속 GPU
> scissor 이관에서 CPU 자르기가 없어지면 사라진다). quad는 여전히 CPU가 rect를 잘라 잘린 변의 radius를 손으로
> 지우므로, 둥근 모서리 정확성은 GPU per-quad clip 이관 뒤에 완성된다.

> **AS4 상태:** 최종 UI는 archive tab이 아니라 우측 dock 안의 하나의 `ExpandedSessionCard` disclosure다. `agent_session_inline_detail`이 cloned, identity-bound DTO를 소유하고 `SessionDock`의 completed tree/action table이 유일한 render/input owner다. `TermRuntime.archive_session_tab`, archive Term/tab/sentinel surface/pane renderer/body pointer·key routing, 그리고 backend `surface_id` multiplexing은 제거됐다. isolated HOME의 AppKit fixture는 list→loading→ready/stale readback, Codex·Claude pointer/key resume·reveal, ready 뒤 source replace reveal 차단에 더해 loading/ready/stale마다 active terminal surface id와 전체 Term 수가 변하지 않음을 확인한다. `detail-close-reopen`은 동일 card pointer로 closed capability 폐기와 새 request id의 loading→ready 재열기를 확인한다. snapshot replacement stale race, expanded scroll anchor, 기본 `SessionDockUiZoom=1000`의 font 14pt/24pt × render scale 1×/2× rect JSON active-host E2E와 Cmd zoom integration test가 완료됐다. exact-live mapping fixture만 별도 잔여 gate다. 최종 계약의 단일 출처는 [에이전트 세션 기록 도크](agent-session-list.md)다.

> 파일 변경 성능 한계: queue slot은 경로 allocation 전에 예약되고 frame-tick의 worker/rename completion apply는 allocation 0·stable group/index O(N)으로 적용된다. ABI v129 `moved_unverified` native callback만 마지막 recovery path 하나를 최대 4,096바이트 복사하며 OOM/초과/invalid path는 경로 불명 fail-close로 강등한다. 다만 최대 dock 256 + recent 32 경로의 rename admission은 아직 main actor에서 expected/replacement를 개별 allocation한다. `file-panel.md`와 `performance-budget.md`가 요구하는 단일 contiguous snapshot + worker `PathRemapPlan`은 미완 gate다. 이 작업은 사용자 명령 1회 경로이고 상한이 고정돼 현재 PR의 frame-tick 안전성에는 영향을 주지 않지만, 288-entry rename의 admission allocation=1 artifact 없이는 해당 성능 계약을 완료로 간주하지 않는다.

| 주소창 텍스트 필드 편집(caret·선택·마우스) | 구현, 일부 환경 의존 | L3 `chrome/components/text_field.zig`가 편집 ops·`fieldLayout`↔`caretAtColumn` 역함수 일치·EAW/그래핌 경계 caret·선택 삭제/대체·가로 스크롤·preedit run을 헤드리스 17 테스트로 고정한다. `AppSession.addr_field`가 이를 소비해 렌더(편집 경로만 `fieldLayout`)·마우스(클릭 caret·드래그 선택·더블클릭 단어·트리플클릭 전체)·키보드(←/→·⌥단어·⌘Home/End·shift 선택·⌘A·⌃A/⌃E·⌫/⌥⌫/⌘⌫)·클립보드(⌘C/⌘X/⌘V)·IME preedit-at-caret을 배선한다. 단일 출처는 [텍스트 필드 에디터](text-field-editor.md). | 마우스 드래그·firstResponder·IME 후보창·클립보드 왕복은 AppKit 경로라 헤드리스로 증명하지 못한다. macOS marked-text 완전 프로토콜은 의도된 최소 stub이라 조합 중 선택-대체·후보창 정확도가 부분적이다([text-field-editor.md] §7). | GUI 손 테스트(드래그 선택, 클릭 caret, 더블클릭 단어, ⌥←/→, ⌘C/⌘X/⌘V, 한글 조합 중 caret 위치, 드래그가 밴드를 벗어나도 웹뷰로 포커스가 새지 않는지). marked-text 완전 프로토콜은 별도 이니셔티브에서 UTF-16 caret 읽기/`replacementRange` 쓰기 ABI와 함께 검증한다. |
| global shortcut | 구현, 환경 의존 | Zig가 `global_hotkeys` descriptor를 소유하고 Swift `registerGlobalHotkeys`가 `RegisterEventHotKey`로 등록한다. 세팅 GUI 녹음/해제·reload·reset은 `take_global_hotkeys_dirty`(ABI v82)로 재등록한다. 헤드리스 테스트가 `.global_hotkey` 섹션 행 노출, rebind의 `global_bindings` 교체, `descriptorFor` null 거부, Backspace 해제, dirty 신호의 1회성을 고정한다. 실제 OS 등록과 **다른 앱과의 충돌**은 headless로 못 잡는다(app smoke는 자동 종료라 등록을 건너뛴다). | 시스템 전역 등록이 다른 앱 핫키와 충돌하는 경우는 자동으로 증명하지 못한다. | 등록 실패(`RegisterEventHotKey` 비-`noErr`)를 관측 가능한 신호로 올려 충돌을 사용자에게 알리는 경로를 추가한다. |
| trace/replay | 구현 | opt-in `MARU_TRACE`가 `app/trace_recorder.zig`로 output/resize/process-exit/input을 `maru.trace.v1`로 증분 기록(파일 sink는 크래시 직전까지 남는다)하고, `observability/replay.zig` `replayTrace`가 GUI 없이 화면을 재구성한다. round-trip 테스트가 "기록한 trace를 replay하면 화면이 재구성된다"를 고정한다. | 라이브 trace를 fixture로 승격할 때 bare 비밀 검출은 자동화되지 않아 사람 검토가 최종 안전망이다([trace-replay.md] §민감정보). | 실패 재현 워크플로(수집된 trace → 회귀 fixture)를 문서화된 runbook으로 굳힌다. |
| OSC52 정책·ask flow | 부분 구현(정책 게이트 완료, ask UI 없음) | **read**: config `osc52.read = allow\|deny`(기본 `deny` — 원격 세션의 클립보드 탈취 방지)가 스키마 1급 키로 노출되고, ABI v75 `take_clipboard_read_request`(정책이 allow일 때만 1)/`provide_clipboard_read`(Swift가 읽은 바이트 → base64 OSC 52 응답을 요청 surface PTY로)로 배선됐다. 코어는 `?` 쿼리 파싱만 하고 실제 클립보드 read는 platform이 한다. **write**: 기본 `allow`가 코드에 하드코딩이고 config 키가 없다(`theme.zig` `Osc52Config` — read만 노출). | **요청별 ask UI가 없다** — 정책이 "전역 allow/deny" 2값뿐이라, 신뢰하지 않는 원격 세션 하나만 골라 거부하거나 사용자에게 그때그때 묻는 흐름이 없다. write는 config 키조차 없어 하드코딩 `allow`를 끌 방법이 없다. | write 정책을 `osc52.write` config 키로 승격하고, 요청별 ask UI(`AppRequest.clipboard` 유사 경로)를 붙일 때 deny/allow completion test와 redacted artifact를 함께 추가한다. |
| shell integration domain event | 부분 구현 | **in-core 이벤트 스트림 구현**: `TerminalCore`가 OSC 133/7을 파싱하며 `types.ShellEvent`(prompt_start·input_start·command_start·command_end{row,exit}·cwd_changed)를 시간순 기록, `shellEvents()`/`clearShellEvents()`로 drain. 같은 도메인 데이터를 결정적 테스트(한 명령 사이클의 경계 이벤트 순서·exit 코드 단언)와 `MARU_DEBUG`의 `shell.*` scoped 로그가 공유한다. app session이 프레임마다 drain(비-debug 폐기·cap 4096 overflow 보고). cwd 값은 `currentCwd()`가 권위(POD 스트림). **trace writer 구현**: `observability/trace.zig`의 `renderShellEvents`/`writeEvent`가 이벤트를 `maru.trace.v1` 텍스트(`event <i> shell.* surface=N ...`, 토큰은 ShellEvent와 1:1)로 직렬화한다 — 실제 OSC 133/7→trace 라인(exit 0/130/none·cwd 따옴표 escape)을 결정적 unit으로 검증(snapshot.zig처럼 writer만). **live 레코딩·replay 구현(위 trace/replay 행)**: `MARU_TRACE`가 켜지면 `app/trace_recorder.zig`가 output/resize/process-exit/input을 파일로 증분 append하고, `observability/replay.zig` `replayTrace`가 되읽어 화면을 재구성한다. `maru trace anonymize`가 캡처한 trace의 PII(경로·IP·user@host·유저명)를 fixture 승격 전에 일반화한다. | app session 디버그 로그는 GUI라 수동 검증이다. 캡처한 trace를 회귀 fixture로 승격하는 판단(bare 비밀 잔존 여부)은 자동화되지 않아 사람 검토가 최종 안전망이다. | shell metadata까지 반영하는 replay 단언(현재 replay는 화면 재구성 중심)을 첫 회귀 trace가 필요해질 때 확장한다. |
| SSH workload | 부분 구현, 환경 의존 | opt-in `mise run ssh-smoke`(`tools/ssh/smoke.sh`)가 `ssh localhost`로 `maru ssh` 전파 경로를 확인한다(sshd나 키가 없으면 skip — 외부 네트워크·특정 원격 서버에 묶이지 않는다는 요건은 지킨다). CI 필수 게이트는 아니다. | 로컬 루프백이라 실제 원격의 latency·locale·terminal mode 차이와 fragmentation 상황(예: SSH에서 Sync 2026이 어긋나 bubbletea TUI가 깨지는 계열)은 재현하지 못한다. | 실 원격 대상 opt-in 환경변수 smoke를 더하고, byte-replay 기반 fragmentation 재현을 회귀로 승격한다. |
| 내장 SSH 클라이언트(프로토콜 코어) | 구현, **실서버 상호운용 확인** | L2 `src/session/ssh/`(패킷·와이어·버전 교환·KEXINIT·KEX·암호·전송 루프·호스트키·`known_hosts`·인증·개인키·채널)가 sans-io 라 실서버 없이 바이트 열로 돌아간다. 공개 근거가 있는 것은 넷이다: **실서버 원문 벡터**(OpenSSH 10.2 의 버전 줄과 KEXINIT 패킷을 그대로 박아 파싱·협상을 고정), **RFC 7748 §6.1 X25519 벡터**, **chacha20-poly1305 초안 Appendix A 의 워크드 예제**(키 재료·시퀀스 번호·평문 패킷·최종 wire 가 전부 있어 키 분할(K_1/K_2)·nonce 인코딩·block counter·Poly1305 키 생성·패딩 규칙·태그를 **바이트 단위로** 한 번에 고정한다 — 이 층은 자기충족이 아니다), 그리고 **명세 상수 대조**(메시지 번호·블록 크기·패딩 하한·표시자 이름을 RFC 숫자/문자열과 직접 맞댄다 — 상수를 쓰는 쪽과 읽는 쪽에 함께 쓰면 자기충족이라 실제로 변이가 살아남았다). **교환 해시 `H` 는 실서버 왕복으로 고정했다** — SSH KEX 에는 `H` 의 공개 벡터가 없어 여태 "명세 해석이 틀렸다면 테스트도 같이 틀린다" 로 남아 있었는데, **서버가 `H` 에 서명한다**는 점을 썼다. 우리 코드가 만든 `V_C`·`I_C`·`Q_C` 를 실제 OpenSSH 10.2 에 보내 받은 `KEX_ECDH_REPLY` 를 벡터로 굳혔고, 그 서명이 우리 `H` 로 검증된다(2026-08-18, 일회용 호스트키로 띄운 임시 sshd — 벡터에는 공개키와 서명뿐이라 비밀이 없다). 이 하나가 버전 줄 취급·KEXINIT 원문 보관·X25519 공유 비밀의 **mpint 인코딩**·해시 필드 순서와 string 프레이밍·협상을 한꺼번에 잡는다(변이 넷으로 검정력 확인). **호스트키·인증·개인키에도 독립 오라클이 있다**: `ssh-keygen -lf`(지문)·`-H`(해시 호스트명)·`-F`(대소문자)·`-p`(암호화/평문 같은 키 한 쌍), RFC 8032 §7.1(Ed25519). `tests/boundary/ssh_sans_io.zig` 가 이 층의 OS 호출 0 을 허용 목록 + 디렉터리 순회로 강제하고, **형제 `.zig` 아닌 import·`@cImport`·`@extern`·`asm` 도 같이 막는다**(앞의 셋은 `std.` 를 안 거쳐 점수 0 으로 빠져나가던 것을 코드리뷰가 잡았다). **잡 메시지(S7c)도 바이트 열로 잰다** — 모르는 번호에 `UNIMPLEMENTED` 를 **거절한 시퀀스 번호와 함께** 돌려주는지(첫 패킷으로 재면 0 이라 아무 값이나 통과하므로 세 번째 패킷으로 잰다), `DISCONNECT` 의 사유·설명이 같은 `Step` 으로 올라오는지, 재키잉 중 `GLOBAL_REQUEST` 의 답이 **줄 서고 나중에 전부** 나가는지(그대로 보내면 §7.1 위반으로 우리 전송기가 스스로를 poison 한다 — 실측으로 재현했다). **끊김은 실서버로도 판정한다** — 스모크 여덟째 회차가 `MaxAuthTries 0` 인 sshd 에 붙어 사유 2 와 `Too many authentication failures` 가 올라오는 것을 단언한다(이 경로는 그 회차 말고 실서버 소비자가 없다). **모바일 C ABI(S9-2)도 같은 실서버로 판정한다** — 아홉·열째 회차(`tools/ssh/abi_smoke.zig`)가 `maru_mobile_ssh_*` **만** 써서 호스트키 승인·셸·화면 바이트·`exit-status` 까지 가고(9), 1MiB 를 **보내고 되받아** 흐름 제어와 부분 전송(`out_consume`)까지 밟는다(10). 코어만 재는 회차들로는 그 사이의 ABI 가 한 줄도 안 지나고, 기기에서 실패했을 때 프로토콜 탓인지 배선 탓인지 가르지 못한다. ABI 계약(핸들 세대·배압·상태/결과 코드 숫자·비밀 소거·0 씨앗 거절)은 `tests/mobile_ssh_contract.zig` 가 **헤더를 그대로 읽어** 대조한다. **기기가 쓸 C 펌프도 같은 실서버로 잰다**(S9-3) — 열한·열두째 회차가 `src/platform/mobile_host/ssh_pump.c` 를 그대로 링크해 호스트키 **핀 고정**으로 붙고(11), 일부러 틀린 지문으로는 `host_key_mismatch` 로 끝나는 것을 단언한다(12). **iOS 는 아직 이 축이 비어 있다**(사용자 확정 2026-08-19 — 실기기 검증이 가능해질 때까지 파일 경로를 쓴다. 시뮬레이터에서는 서명 entitlement 문제로 Keychain 을 아예 못 밟는다). **Android 는 그 키를 Keystore 로 봉인하고 재사용한다**(에뮬레이터 실측: 첫 실행에 만들어 붙고, 다시 실행하면 **새로 안 만들고** 같은 공개키로 붙는다. 봉인 파일을 망가뜨리면 `AEADBadTagException` → 새로 만들지 않고 접속을 포기한다). **중계의 `SIGPIPE` 규칙은 테스트로 못 잰다** — 실측(2026-08-21): Zig 로 빌드한 보통 실행 파일은 닫힌 파이프에 쓰면 `SIGPIPE` 로 죽지만(`exit 141`) **테스트 러너는 그 신호를 이미 가로채 둔다**. 그래서 그 테스트는 기본 동작일 때만 뜻이 있고, 아니면 **건너뛴다**(초록으로 위장하지 않는다 — 변이 검사가 그 자리를 먼저 잡았다). 무시를 빼면 제품 경로에서 중계가 끝 메시지도 없이 사라진다. **폰에서 실서버까지 손으로 한 번 확인했다**(2026-08-21, iOS 시뮬레이터 + 맥의 임시 sshd): SSH 접속·명령 전달·에코·프롬프트 색·커서가 정상이고(`echo MARU_LIVE_OK; uname -s` → `MARU_LIVE_OK`/`Darwin`), **한글 표시**도 양폭으로 제대로 그려진다(`echo $'\uc548\ub155 \ud55c\uae00'` → `안녕 한글`). **한글 입력은 자동으로 못 잰다** — `idb ui text` 는 키코드 기반이라 한글을 못 보내고(`No keycode found for 안`), 하드웨어 키보드 합성 입력과 소프트 키보드 토글도 이 환경에서는 안 먹었다. 사람이 시뮬레이터에서 직접 쳐서 확인했고, 조합 경로 자체의 규칙(`maru_mobile_set_preedit`)은 브리지 계약 테스트가 잰다(조합 문자열이 코어를 안 더럽힌다 · 여러 바이트 글자가 앞 글자를 안 지운다 · 넘치면 잘린 글자를 통째로 버린다). **중계는 손으로 한 번 왕복시켰다**(2026-08-21, S10c 의 미검증 자리): maru 앱을 띄운 뒤 `echo '{"jsonrpc":"2.0","id":1,"method":"sessions.list"}' | maru control --stdio` 가 `hello`(protocol=`maru.control.v1`, capabilities 18개)와 응답을 그대로 냈고, 끝맺음은 stderr 로 `maru control: maru closed the control socket` 이었다 — **끝을 세 갈래로 가른다** 가 선 위에서 성립한다. 자동 게이트는 아니다(GUI 인스턴스가 필요해 CI 밖) — 그래서 여기 적어 둔다. **폰의 ndjson 클라이언트(S10d-1)는 OS 없이 전부 잰다** — 줄 조립·프레임 상한·`hello` 찾기(앞의 잡음을 버리는 것과 그 상한)·프로토콜 판정·capabilities 는 시계도 소켓도 없는 층이라 `zig build test-mobile-control` 이 그대로 잰다. **지어낸 문자열이 아니라 서버의 직렬화기(`control_plane.serializeHello`)가 만든 바이트**를 먹여, 필드 자리·따옴표·배열 표기가 우리 판정과 어긋나지 않는지 본다(어긋나면 기기에서 "왜인지 축이 안 선다" 로만 보인다). **ABI·화면(S10d-2)은 브리지 계약 테스트가 잰다** — 목록이 ABI 를 지나오는지, 그리고 **그리기 경로 안에서 세워진 판정**(`remoteSessionsShown`)으로 화면이 세 상태(받는 중·없다·줄들)를 갈라 그리는지. 값만 맞고 닿는 자리가 틀린 결함을 이 저장소가 여러 번 겪어서 그렇게 잰다(실제로 그 테스트가 "화면이 sessions 가 아니라 그리기가 아예 안 도는" 자리를 잡았다). **아직 실서버로는 안 밟는다**: 스모크의 컨트롤 회차는 `echo` 를 돌리지 실제 `hello` 를 주고받지 않고, 그러려면 그 기계에 GUI 인스턴스가 떠 있어야 한다(CI 밖) — S10d-3 이 그 회차를 정한다. **원격 중계(S10c)는 파이프와 소켓쌍으로 진짜 왕복을 잰다** — `maru control --stdio` 의 중계 루프는 fd 를 인자로 받으므로(`relayFds`), 테스트가 파이프 둘과 `socketpair` 하나를 물려 **바이트가 그대로 오가는지**를 실제 syscall 로 확인한다(줄 경계에 안 맞는 조각을 일부러 섞는다 — 중계는 프레임을 모으지 않는다는 계약을 그것으로 잰다). 끝은 세 갈래(`stdin_eof`·`socket_eof`·`io_error`)로 갈리고 그 구별도 잰다 — 뭉치면 "폰이 나갔다" 와 "maru 가 꺼졌다" 가 같은 말이 되어 화면이 할 말을 못 고른다. **다만 소켓 발견부터 끝까지는 안 잰다**: 그러려면 GUI 인스턴스가 떠 있어야 하고 CI 에는 없다. **서버가 여는 채널을 거절하는 경로는 실서버로 못 잰다** — 그 메시지는 우리가 agent·X11·원격 포워딩을 **요청해야** 오는데 우리는 그 요청을 안 한다(계약 §3.4 "안 하는 것"). 즉 트리거를 우리가 만들지 않으므로 sshd 를 어떻게 띄워도 안 온다. 근거는 단위 테스트뿐이고(§5.1 자리대로 바이트를 손으로 뜯어 상대가 보낸 sender channel 과 사유 3 을 확인, 변이 셋으로 검정력 확인), 그 사실을 여기 적어 둔다 — "실서버로도 봤다" 로 읽히면 안 된다. **컨트롤 채널도 실서버로 판정한다**(S10b-1) — 열일곱째 회차가 터미널이 뜬 뒤 같은 연결에 채널을 하나 더 열어 `exec` 으로 명령을 돌리고, 그 출력이 **컨트롤 버퍼로 오고 화면에는 안 섞이는지**와 그러고도 터미널이 사는지를 단언한다. 열여덟째 회차는 **없는 명령**을 돌려 계약(§4a)이 적은 대로 **채널 요청은 성공하고 `exit-status` 로 127 이 오는 것**을 실측한다(`CHANNEL_FAILURE` 를 기다리면 영영 안 온다). 이 두 회차의 sshd 는 **`ForceCommand` 를 안 건다** — 나머지 회차 서버는 전부 강제 명령이라 우리 `exec` 이 무시되고, 그 상태로는 이 축이 아무것도 못 잰다(그 무시되는 성질 자체가 계약이 강제 명령 서버에서 컨트롤 축을 안 켜는 이유다). **기기에서 만든 키도 실서버로 판정한다** — 열네째 회차가 `maru_mobile_ssh_generate_key` 로 만든 공개키 줄을 `ssh-keygen -lf` 로 먼저 읽히고(형식을 남의 도구가 판정한다), 그 줄을 `authorized_keys` 에 넣은 sshd 에 **그 키로 붙는다**(변이 둘로 검정력 확인: 공개키를 씨앗으로 바꿔치기·알고리즘 이름 오타). **펌프는 재키잉도 지난다** — 열세째 회차가 `RekeyLimit 1M` 서버에서 12.6MB 를 받으며 `maru_mobile_ssh_rekeys` 로 **16 회**를 세어 단언한다(안 세면 키를 한 번도 안 갈아도 초록이다). 그 회차가 기기 전에 세 결함을 잡았다: 스레드 기본 스택으로는 첫 `feed` 에서 죽는다(`SIGILL`), 먹다 남은 바이트를 버리면 패킷이 읽기 경계에 걸릴 때 세션이 끝난다, 상태만 옮기는 걸음(호스트키 승인) 뒤에 밀어 주지 않으면 서로 기다리며 멈춘다. **그 "서로 기다린다" 의 나머지 절반이 송신 쪽에 남아 있었다**(2026-08-23 기기 실측) — 친 글자를 소켓에 내보내는 것은 루프 머리의 `flush_out` 인데 거기 닿으려면 `read` 가 리턴해야 하고, 펌프를 깨울 수단이 없어 그 조건이 **서버가 먼저 말하거나 2초(`PUMP_READ_TIMEOUT_S`)가 지나는 것** 뿐이었다. 조용한 프롬프트에서 한 글자가 최대 2초 묶였고, 연타하면 에코가 대신 깨워 줘서 빨라져 **가끔 느린 것처럼** 보였다. 깨우기 관(`pipe`)을 넣어 쓸 것이 생긴 순간 `poll` 이 깨어난다. **그 효과는 `stop` 이 대신 잰다** — 예전에는 정지 표시만 세우고 타임아웃까지 붙들려 그 단언 상한이 4000ms 였는데, 그 느슨함이 같은 결함을 덮고 있었다. 지금은 500ms 이고 `stop` 의 `pump_wake()` 를 지우면 곧바로 빨개진다(변이로 확인). **쓰기 경로 자체는 거기서 못 잰다** — 핸드셰이크가 선 세션이 있어야 `write` 가 받아 주는데 그 상대는 조용해서 거기까지 못 간다. 같은 `pump_wake()` 를 쓰므로 메커니즘은 그 단언이 증명하고, 실제 타이핑 체감은 기기 회차가 판정한다. 그 적대적 검증이 **코어의 반쪽 계약**도 하나 찾았다 — 계약이 "호스트키는 재키잉마다 다시 검증한다" 고 적어 뒀는데 코드는 *서명*만 봤고, 서명은 제시된 키로 확인하므로 **다른 키로 갈아 끼워도 통과**했다. 지금은 처음 승인한 키와 바이트가 같아야 하고 다르면 `HostKeyChanged` 다(변이 셋으로 검정력 확인). `zig build check-ssh-modes` 가 이 층을 **Debug·ReleaseSafe·ReleaseFast 셋 다** 돌린다 — `std` 의 몇몇 검사가 `runtime_safety` 뒤에 있어 배포가 쓰는 ReleaseFast 에서 사라지는데 `zig build test` 는 Debug 라 CI 가 영영 못 본다. | **스모크가 기본 `check` 에 안 든다** — `sshd` 바이너리와 포트가 필요해 환경 의존이고, 없으면 SKIP 한다. 즉 회귀 방어는 **그 태스크를 돌린 사람에게만** 걸린다. CI 에 올릴 때는 `MARU_SSH_SMOKE_REQUIRE=1` 을 켠다 — 그러면 SKIP 이 실패가 된다. 안 켜면 러너에 sshd 가 없거나 포트가 막혔을 때 **아무것도 안 재면서 초록**이 된다(적대적 검증이 실측했다). 확인한 서버는 **OpenSSH 10.2 하나**이고 Dropbear·네트워크 장비는 다르게 굴 수 있다. `keyboard-interactive` 를 안 하므로 그것만 여는 서버에는 여전히 못 붙는다. | **상호운용이 상시 검증된다** — `mise run ssh-client-smoke` 가 **일회용 호스트키·클라이언트키로 자기 sshd 를 띄우고**(사용자 키·Remote Login 을 안 쓴다) 우리 코드만으로 붙어 버전 교환→KEX→호스트키 검증→암호화→publickey 인증→채널 열기→`pty-req`→`shell`→**8MiB 수신**→`exit-status`→종료까지 간다. 8MiB 는 우리 윈도(2MiB)의 네 배라 흐름 제어가 실제로 돈다 — 스모크가 **보충 횟수까지 단언**한다(1MiB 로는 절반 경계라 한 번도 안 돌면서 초록이 된다는 것을 실측했다). 남은 것은 S9(모바일 배선). 단일 출처: [SSH 클라이언트 계약](ssh-client.md), [구현 계획](plans/ssh-client.md). |
| 긴 soak/제품 성능 예산 | 부분 구현, 환경 의존 | `mise run perf`(core 기준: `scrollback_rewrap`·`kitty_image_pipeline`·`render_build_scrolled`·`core_command_queue` 등)에 더해 제품 경로 job이 붙었다 — `macos-file-explorer-perf`(실 AppSession 16,384-row/1,000-event counter, required status). `macos-mermaid-perf`는 **CI job에서 제거해 로컬 명령으로만 남겼다**([필수 CI 체크](performance-budget.md#필수-ci-체크) 참조). [성능 예산](performance-budget.md)은 main tick pump p95/max, WebKit result bridge handoff, outbound queue 상한, host·app+WebContent RSS delta까지 숫자로 정의한다. | **긴 soak(장시간 연속 구동)과 앱 시작 시간·키 입력→화면 지연(end-to-end latency)은 여전히 측정하지 않는다.** 예산이 정의된 항목도 일부는 해당 기능 job 안에서만 재고, 전역 회귀로는 못 잡는다. | startup/입력 지연 계측을 macOS 제품 job에 추가하고, 장시간 soak(메모리 증가·핸들 누수)을 opt-in job으로 분리한다. |

파일 도크 닫기·트리 키보드·파일 변경 행의 **필수 보안 하위 gate**는 [file-panel-verification.md §11](file-panel-verification.md#11-테스트검증)을 normative 목록으로 삼는다. 특히 source-edit native-clean snapshot sync, root/parent/leaf identity 교체와 atomic no-replace 경쟁, 비-dot staging Trash handoff·rollback·destination identity 성공 판정, mutation pending 중 stale bridge 요청, `.md↔.html` 및 지원→비지원 kind 전이를 생략한 구현 PR은 위 행을 통과한 것으로 보지 않는다.

호환성/보안 기본값(`TERM`, OSC52, bracketed paste, shell integration, command restore, plugin permission, update/telemetry, global shortcut)은 [터미널 호환성/보안 정책](terminal-compatibility-policy.md)의 검증 계획을 따른다. 새 구현 PR이 이 기본값을 바꾸려면 사용자와 먼저 논의하고, 이 매트릭스의 자동/수동 검증 경로도 함께 갱신한다.

### Session host 실행 중 업그레이드 gate

[Session host 실행 중 업그레이드](session-host-upgrade.md)는 U0 inventory, U1 codec, U2 quiesce 핵심,
U3 exec/rollback fixture, U4 typed-connect/host-pool 기반과 U5 제품 daemon controller·preflight·pathname exec·
target/rollback restore activation, quiesce 전 handoff-size/disk/I/O budget admission, crash 뒤 owner-only stale attempt/target sweep까지 연결했다. caller-attested frozen signed N-1/current non-empty PTY 성공
경로의 opt-in 자동 하네스도 구현했지만 실제 서명 release artifact로 아직 실행하지 않았다. zero-runtime 제품 rollback activation과
listener 재접속은 actual product exec와 MRSH client gate로 검증했다. non-empty PTY rollback activation도 actual
product exec와 real PTY/MRSH client gate로 검증했다. 최대치 근처 multi-runtime 제품 restore, 전 구간 failure injection,
앱 재실행 orchestration과 soak가 남아 있으므로 U5 완료나
기본 자동 migration을 주장하지 않는다. 단계별 증거 수준을 섞지 않는다.

| 단계 | 목표 종료 gate | 현재 증거만으로 완료로 보지 않는 것 |
| --- | --- | --- |
| U0 inventory | terminal core/scrollback·PTY/reader/queue·Surface/runtime registry/link·RuntimeManager·SocketServer owner field가 `serialized`·`reconstructed`·`inherited_resource`·`must_be_empty` 중 정확히 하나이며 새/중복/없는 필드는 compile fail | field 이름 분류만으로 실제 state round-trip을 증명하지 않는다 |
| U1 codec | bounded envelope/TLV round-trip과 **모든 inventory field의 encode→decode 동등성**, partial UTF-8/CSI/OSC/DCS/APC, duplicate/unknown-required/cap/checksum/OOM | codec helper나 일부 representative field만으로 실제 PTY fd나 child 보존·inventory 완전성을 증명하지 않는다 |
| U2 quiesce | admission close, accepted reply flush와 reactor idle-slot bounded drain, attachment/connection 0 재검사, input/core-command/response fence flush, reader iteration barrier, cooperative deadline budget·continuous output 뒤 원상 재개 | 같은 process quiesce/resume만으로 binary 교체를 증명하지 않는다. blocking syscall 중 실제 pause wall time의 절대 상한은 주장하지 않는다 |
| U3 exec | frozen old **release** binary→new release binary, host/child PID·host/runtime ID 불변, post-upgrade input/output, exit status exact-once, 전 pre-commit failpoint rollback | 현재 source와 함께 재컴파일한 old fixture나 current binary 양면 실행은 frozen N-1 호환 증거가 아니다 |
| U4 adapter | current GUI→frozen N-1 MRSH adapter→upgrade→current attach, multi-runtime all-or-none, busy attachment side-by-side fallback | capability-tagged socketpair fixture와 current daemon 두 개의 host-pool E2E만으로 실제 구 release binary 호환을 부르지 않는다 |
| U5 제품 | checksummed attempt ledger v3는 distinct target+canonical rollback image, 64 MiB two-copy preallocation, absolute deadline과 exact host/epoch/runtime set을 고정한다. 제품 daemon은 rollback self-image, **same-designated-requirement** codesign stager, controller, preflight와 strict pathname `execv`를 연결했다. quiesce 전 budget admission은 read-only codec preview, exact two-copy `F_PREALLOCATE`, 같은 파일의 incompressible durable probe와 4배 safety factor를 통과한 뒤에만 reader pause를 허용한다. authoritative capture의 membership/runtime set/길이는 reservation과 다시 대조하고, 예약 owner가 성공·in-process rollback·deadline에서 pathname/fd를 exact-once 정리하며 cleanup failure는 fail-stop한다. target/rollback bootstrap은 inherited PTY/owner/state FD와 role/image를 검증하고, `ready` commit→graph ownership→inherited fd close→reader release→rollback promotion→ledger→capability/admission 순서를 강제한다. crash residue sweep은 exact host owner lock 뒤 capability 광고 전에 실행하며 exact attempt/target/tomb 이름·UID·mode/type/link count·pinned dev/inode·closed child vocabulary를 전부 검증한 뒤 no-replace tomb를 거쳐 제거한다. drift/unknown/정리 실패는 keep-alive service를 보존하고 새 upgrade admission만 fail-close한다. zero-runtime product artifact, real-PTY old-side rollback, partial-prepare all-or-none, unexpected FD와 primary/backup/promotion failure component gate, valid/hostile residue의 실제 fork/socket daemon capability gate가 있다. `test-session-host-upgrade-product-rollback`은 corrupt target primary에서 canonical product rollback을 실제 exec하고 동일 peer PID의 listener에 MRSH client로 재접속해 old build/epoch, `rolled_back/restore_failed`, capability와 empty inventory를 단언한다. `test-session-host-upgrade-nonempty-rollback`은 supervised source-host가 직접 만든 PTY의 direct-child 관계, exact runtime identity, pre/post I/O와 exit-23 명령 뒤 host-owned reap/inventory 제거까지 한 process artifact로 검증한다. signed 성공 하네스도 복원 뒤 PTY 종료 marker를 보내 direct child 부재와 `runtime.list` 연속 2회 부재를 요구하며 `runtime.terminate` 단축 경로를 금지한다. exit status 숫자 자체는 wire 관측 증거로 주장하지 않는다. pathname 재-open은 kernel-loaded image pin이 아니며 pathname object identity+same-designated-requirement signer+same UID만 executable trust boundary다. | `connectOrLaunchDetailed`는 선택한 old host의 `upgraded`·`upgrade_busy`·`legacy_unavailable`·`upgrade_failed`를 bounded typed `UpgradeNotice`로 반환하고, AppSession은 최종 current-host 연결 성공 뒤 modal-free frame에서 정확히 한 번 표시한다. 로그와 UI는 같은 DTO를 쓰며 최종 host 연결 실패가 더 강한 notice로 우선한다. 이 자동 gate는 형식·보존·우선순위를 검증하지만 실제 앱 재실행 화면 증거는 아니다. signed 성공 하네스의 command·artifact·수명 검사는 구현됐지만 실제 immutable release manifest에 결속된 frozen N-1/current 서명 artifact로 아직 실행하지 않았다. 그 provenance-bound 실행, 1개·최대치 multi-runtime exact reattach, 전 구간 failure injection, 실제 app relaunch/notice와 soak가 남았다. 이 gate 전에는 U5 완료·제품 migration 완료·기본 자동 migration을 주장하지 않는다. |

U5 Release evidence의 OS 중립 canonical aggregate core는 **구현**됐다. `test-session-host-release-evidence`가
Debug·ReleaseFast에서 `maru.session-host-release-evidence.v1`의 `baseline_a`의
default-false/signed-app-quit 두 gate와 `upgrade_b`의 signed 1-runtime/near-max 두 gate를 exact profile로 분리한다.
repository/release/source/build run-attempt, candidate DMG·executable, B predecessor release/manifest/asset과 canonical UUID를
typed nested observation에 결속한다. `UpgradeExpected.designated_requirement_sha256`는 one/near-max 두 leaf가 같은 값이라는
내부 일치뿐 아니라 caller가 manifest/Apple product에서 유도한 expected signer requirement와도 exact 일치하게 하므로, 같은 foreign
signer를 두 leaf에 반복한 replay도 거부한다. ephemeral leaf SHA나 raw base64를 durable 권위로 쓰지 않는다. 별도 G3 default-on matrix는
이 schema의 optional gate가 아니다. leaf의 no-follow file 입력·exclusive aggregate publication, signed 제품 leaf 실행,
artifact attestation과 release workflow 배선은 여전히 미구현이므로 이 component green만으로 U5 release나 G3 준비·출하를
주장하지 않는다.

U5 Release evidence filesystem 조립은 `release_evidence_files.zig`가 profile별 exact leaf를
`release_adapter_files.readInputAlloc`로 bounded no-follow read하고 opened `(device,inode)` distinctness를 확인한 뒤 OS 중립
aggregate core에 전달한다. canonical bytes를 expected identity에 다시 bind한 뒤에만 absent output에
`publishSummaryExclusive`하며, symlink·hardlink alias·malformed/mismatch·기존 output·allocation failure에서는 publication 0이다.
`test-session-host-release-evidence-files`가 이를 actual macOS filesystem의 Debug·ReleaseFast gate로 검증한다. 이 행은 caller
identity의 GitHub provenance, signed leaf 생산, artifact attestation이나 release workflow 배선을 완료로 바꾸지 않는다.
special/oversize/read-drift는 하위 `test-session-host-release-adapter-files`가 소유하며 이 조립 gate의 직접 증거가 아니다.

U5 baseline-A의 signed app Quit leaf 생산은 **부분 구현**이다. opt-in
`macos-session-host-signed-app-quit-evidence`가 trusted UUID와 actual candidate DMG·frozen executable을 no-follow digest로 고정하고,
strict signed app에서 actual AppKit Quit→재실행을 수행해 host/runtime/child PID, 기존 화면, 재접속 뒤 입력·화면, exact GUI reattach와
cleanup을 관측한 뒤 canonical leaf를 exclusive `0600` output으로 게시한다. focused
`test-session-host-signed-app-quit-evidence`는 canonical writer·UUID 거부와 source-level stale invalidation·exclusive output 경계를
검증한다. 이 증거는 GitHub candidate
attestation, default-false leaf 생산, 두 baseline leaf의 trusted workflow 실행이나 aggregate publication을 대신하지 않는다.

U5 baseline-A의 default-false leaf 생산은 실제 signed app bootstrap 관측을 종료 gate로 삼는다. opt-in
`macos-session-host-default-false-evidence`는 trusted UUID와 candidate DMG·frozen executable을 no-follow digest 및 strict signer로
고정하고, 사용자 config·session-host registry와 분리된 비어 있는 root에서 actual app executable을 시작한다. 제품 bootstrap 직후
Zig owner snapshot의 exact `false/absent/missing`을 닫힌 ABI 결과로 관측하고 candidate 재검증과 정상 child 종료 뒤에만 canonical
`maru.session-host-default-false-baseline.v1` leaf를 exclusive `0600`으로 게시해야 한다. focused
`test-session-host-default-false-evidence`는 schema SSOT, ABI enum의 닫힘, stale output invalidation, caller 결과 bool 0, candidate
재검증과 exclusive publication 경계를 검증한다. 이 gate는 G3 default-on 승인, GitHub provenance, DMG notarization 또는 두 A leaf의
trusted workflow 실행·aggregate publication을 대신하지 않는다.

U5 signed candidate staging은 universal build가 공증·staple 검증한 app과 DMG를
`dist/session-host-candidate-<version>/`에 배타 게시하고 app main executable과 별도 frozen executable의 exact bytes를 두 번
대조한다. `tools/test-macos-release-candidate-artifacts.sh`는 실제 임시 filesystem에서 exact 세 산출물, executable mode,
기존 final·symlink 거부, copy/비교 실패 시 final publication 0을 검증한다. 이 gate는 Apple 서명·공증 자체나 GitHub workflow의
baseline leaf 실행·attestation·release publication을 대신하지 않는다.

U5 signed baseline product gate의 실행 경로는 공통 `session-host-signed-candidate-app` 옵션 하나가 소유한다. 두 gate는 그 bundle의
`Contents/MacOS/maru-macos-app`을 실행하고 signed-app-quit만 같은 bundle의 `Contents/MacOS/maru`를 사용한다. release gate에
`macos-app-bundle`, `zig-out/Maru.app` 또는 checkout `web/dist` fallback/dependency가 남으면 실패하는 focused boundary를 둔다.

U5 baseline child 경로 gate는 workspace owner가 봉인한 두 HOME과 두 leaf absolute pathname을 네 필수 build option으로 전달한다.
각 HOME은 absent child를 mode `0700`으로 배타 생성하고 leaf는 absent여야 하며, build/AppKit 하네스는 고정 `zig-out` 경로,
`/tmp/maru-product-test-*` registry 또는 stale pathname 삭제를 사용하지 않는다. focused source boundary는 option 누락·상대경로,
HOME/leaf alias, 기존 HOME/leaf와 release harness의 unlink를 거부하고 두 제품 entrypoint가 exact injected HOME/config/registry/leaf를
소비하는지 검증한다. 이 gate는 production runner의 candidate 재검증·역순 cleanup·aggregate publication을 대신하지 않는다.
실제 Developer ID candidate 실행은 trusted release workflow가 이 옵션에 앞선 staging app absolute pathname을 전달할 때 완료된다.

U5 baseline child의 Zig 실행 권위는 protected tag와 같은 source SHA의 GitHub-hosted macOS ARM64 runner가 mise 설치 직후 고정한
canonical absolute pathname·size·SHA-256과 exact version `0.16.0`이다. final-address `ZigToolchainAuthority`는 held file과 pathname,
parent identity를 child 실행 직전·직후 재검증하고 raw caller pathname을 baseline executor에 노출하지 않는다.
`test-session-host-release-adapter-zig-toolchain-authority`는 Debug·ReleaseFast actual filesystem에서 owner와 drift 경계를 검증하고,
workflow contract gate는 capture가 mise 뒤·baseline 실행 앞에 있으며 version/path/size/digest를 모두 게시하는지 고정한다. macOS에 없는
fd-exec를 요구하지 않으며 같은 UID의 비신뢰 동시 pathname swap은 GitHub-hosted 격리 release job의 threat model 밖이다. 로컬 빌드와
로컬 업그레이드는 공식 release evidence 권위를 요구하지 않는다. 이 행은 두 baseline child의 workflow phase orchestration이나
Developer ID candidate 실행 완료를 단독으로 증명하지 않는다.

U5 held evidence input은 게시된 `PinnedReleaseFile`의 final pathname identity를 전후로 확인하면서 bytes는 기존 held fd에서만
bounded exact read한다. 최초 inode/size/SHA와 read 전후 fingerprint·EOF가 모두 같을 때만 `Input`을 반환하며 copied owner,
pathname replacement, cap·allocation·content drift에서는 publication 0이다. `test-session-host-release-adapter-files`가 actual
filesystem의 exact read와 replacement 보존 및 allocation failure를 검증한다. manifest semantic authoring은 별도 gate다.

U5 candidate manifest authoring은 trusted candidate/product/source/compatibility/evidence authority와 role B predecessor authority
graph만으로 canonical manifest를 유도한다. held evidence bytes가 정한 role/profile을 candidate identity에 exact bind하고 세 asset의
basename·size·SHA, Apple signing, compatibility, test UUID와 result를 caller scalar 없이 채운다. encode+self-parse 뒤 output open
직전에 전체 graph와 held evidence inode를 최초 fixed snapshot과 다시 비교하며 copied/pre-owned/alias owner, malformed·교환
evidence, authority drift, 기존 output과 allocation fail-index에서는 publication 0이다. focused
`test-session-host-release-adapter-candidate-manifest`가 role A/B actual filesystem publication과 실패 경계를 Debug·ReleaseFast에서
검증한다. 같은 parent의 manifest sibling 게시 뒤에도 evidence의 exact held/reopened leaf authority가 유지되며, sibling
mtime/ctime은 일반 file identity가 아니다. 실행 pathname mutation 봉인은 executable 전용 seal이 계속 소유한다. aggregate
attestation과 draft attach/publish 및 frozen signed 제품 실행은 별도 gate다.

U5 artifact attestation 발급 action은 한 invocation이 canonical absolute regular-file subject 정확히 하나만 소유한다.
`test-session-host-release-attestation-action`은 local composite action의 pre-pin→immutable `actions/attest` exact once→post-pin 순서,
고정 provenance mode, device/inode/link-count/size/SHA 불변과 glob·CSV 목록·symlink·hardlink·빈/control-character output 거부를 정적으로 고정한다. candidate DMG/frozen
executable과 authored evidence/manifest는 최종 release workflow가 이 action을 네 번 따로 호출한다. 이 component는 workflow
permissions, protected environment, 실제 attestation 발급이나 draft attach/publish를 완료했다는 증거가 아니다.

U5 exact draft asset attachment는 `DraftAuthority.id`와 candidate/authored attestation, canonical held manifest와 네 distinct held file
authority에서만 DMG→frozen executable→evidence→manifest upload를 유도한다. `test-session-host-release-adapter-draft-assets`는
uploads endpoint의 exact release ID/name, held-fd body streaming, strict response ID/name/size/digest/content-type/state, shared deadline과 전후 graph
revalidation을 Debug·ReleaseFast에서 검증한다. 첫 remote mutation 뒤 partial failure는 자동 retry·reuse·delete하지 않고 known ID를
cleanup-required 또는 불확정 호출을 remote-state-unknown terminal audit state로 보존해야 한다. 이 gate는 draft redownload validation,
publish, post-publish release attestation이나 frozen signed U5 제품 E2E 증거가 아니다.

- `test-session-host-release-adapter-post-publish-attestation`은 ready published authority와 원본 ready attachment/redownload 영수증 및 attachment graph를 다시 결속하고,
  GitHub tag ref/annotated chain을 manifest source commit까지 bounded 수렴시킨 뒤 release verify exact 1회와 held 네 asset의
  verify-asset exact 4회를 수행한다. tag-ref SHA와 source commit을 구분하고 각 child 전후 CLI·held inode·publication graph,
  shared deadline, move-only result와 실패 publication 0을 Debug·ReleaseFast typed composition에서 검증한다. actual held filesystem
  재검증은 매 snapshot이 호출하는 draft-assets gate가 별도로 소유한다. live release workflow나
  frozen signed U5 제품 E2E의 증거는 아니다.

U5 exact draft asset redownload는 ready `DraftAuthority`·`DraftAssets`와 candidate/authored attestation, canonical held manifest 및 네 held
file authority에서만 exact GitHub asset ID와 expected name/size/SHA를 유도한다. `test-session-host-release-adapter-draft-redownload`는
DMG→frozen executable→evidence→manifest exact request 순서, clean token environment, body 비저장 bounded streaming count/SHA, shared
deadline과 child 전후 전체 graph revalidation을 Debug·ReleaseFast에서 검증한다. oversized·short·digest mismatch, duplicate/foreign ID,
timeout, copied/pre-owned/alias owner와 authority drift는 validation publication 0이고 기존 draft/attachment state를 변경하지 않아야 한다.
이 gate는 draft publish, post-publish release attestation, live workflow 또는 frozen signed U5 제품 E2E 증거가 아니다.

U5 exact draft publication은 ready attachment/redownload receipt와 전체 typed graph가 같은 exact release/asset set을 가리킨 뒤에만
`DraftAuthority.id`에 `draft=false`, `prerelease=false` 단일 PATCH를 허용한다. `test-session-host-release-adapter-draft-publish`는
closed argv/clean environment/shared deadline, published immutable response의 exact ID/tag/source/lifecycle과 네 asset
ID/name/size/digest/content-type 집합, copied/pre-owned result, duplicate asset authority와 authority drift를 Debug·ReleaseFast에서 검증한다.
mutation 전 두 authority snapshot allocation failure는 mutation 0과 empty를, response 뒤 snapshot allocation failure는 exact release ID가
있는 cleanup-required를 보존해야 한다. remote mutation 시작 뒤 timeout·child/parse/allocation 실패는 자동 retry 가능한 empty로 돌아가지
않고 remote-state-unknown 또는 cleanup-required audit state를 보존해야 한다. 이 gate는 post-publish release attestation, live workflow
또는 frozen signed U5 제품 E2E 증거가 아니다.

U5 baseline-A candidate evidence 조립은 `release_adapter_candidate_baseline_evidence.zig`가 trusted context와 final-address
candidate evidence identity의 backing file/product/source authority에서만 canonical common identity를 유도한다. 최초 view를
fixed snapshot으로 봉인하고 두 leaf의 canonical aggregate가 완성된 뒤 output open 직전에 같은 authority를 다시 검증해 exact
snapshot과 비교한다. encode/parse allocator callback, copied/pre-owned/alias owner, identity/product/source/path drift,
malformed·교환 leaf, 기존 output과 allocation failure에서는 publication 0이며 성공은 held output inode authority 하나다.
`test-session-host-release-adapter-candidate-baseline-evidence`가 이를 actual macOS filesystem의 Debug·ReleaseFast gate로 검증한다.
signed leaf 실행, aggregate attestation, manifest/draft publication과 U5 signed frozen 제품 실행은 이 행의 증거가 아니다.

U5 baseline-A signed leaf transaction은 `release_adapter_candidate_baseline_phase.zig`가 하나의 absolute deadline과 trusted
candidate identity 아래 initial candidate 재검증→default-false→candidate 재검증→signed-app-quit→candidate 재검증→aggregate publication→final
candidate/deadline 재검증 순서를 고정한다. 실패는 attempted aggregate→signed-app-quit→default-false child를 역순 best-effort
정리하고 cleanup failure를 terminal로 승격한다. 실패한 cleanup의 retry authority와 residue는 제품 owner가 보존하며, 성공만 세
child owner를 후속 manifest/attestation 단계에 전달한다.
`test-session-host-release-adapter-candidate-baseline-phase`는 순서·deadline pointer·모든 fail-index·final drift·cleanup failure를
Debug·ReleaseFast production-type transaction으로 검증한다. 제품 runner와 trusted workflow caller는 아직 후속이다.

U5 baseline-A product execution의 final-address ownership core는 `release_adapter_candidate_baseline_product.zig`가 preserved
candidate/work root에서 app main·bundled CLI와 서로 다른 child root를 유도하고, copied/pre-owned execution을 callback 전에
거부한 뒤 기존 baseline phase의 attempt를 caller-owned `Execution`에 기록한다. success owner retention과 reverse cleanup,
cleanup-failure exact retry set을 `test-session-host-release-adapter-candidate-baseline-product`가 Debug·ReleaseFast에서 검증한다.
concrete typed candidate graph와 app/frozen bytes·SHA·strict signer를 결속하는 `bindCandidate`, actual filesystem leaf runner 및
aggregate publisher, workflow caller·artifact attestation·manifest/draft publication과 frozen U5 전체 E2E는 후속 증거다.

U5 baseline-A preserved candidate app authority는 `release_adapter_candidate_baseline_app.zig`가 candidate product의 frozen SHA와
designated-requirement digest에 `Maru.app` main·bundled CLI의 held no-follow executable identity를 결속한다. main/frozen digest 불일치,
두 executable의 signer 불일치, symlink·hardlink·같은 inode·관측 중 pathname/candidate drift와 copied/pre-owned/alias result는 child 실행
전에 실패한다. `test-session-host-release-adapter-candidate-baseline-app`은 actual macOS filesystem에서 이 결속과 final-address owner의
재검증·해제를 Debug·ReleaseFast로 검증한다. 실제 AppKit/CLI 실행, 격리 HOME/config/session registry, leaf/evidence publication과 release
workflow 배선은 후속 runner 증거다.

U5 baseline-A runner workspace는 `release_adapter_candidate_baseline_workspace.zig`가 기존
`release_adapter_pre_publish_workspace.zig`의 descriptor-owned 0700 root를 소비해 `default-false`·`signed-app-quit` HOME, 두 leaf와
aggregate output의 exact absent path를 한 final-address owner에 봉인한다. ambient HOME/config와 실제 `/tmp/maru-<uid>`는 입력도
cleanup 대상도 아니다. copied/pre-owned owner, owner/path storage alias, root 교체·unexpected child·sync failure는 foreign deletion 0과
retry authority를 보존한다. `test-session-host-release-adapter-candidate-baseline-workspace`가 actual filesystem의 Debug·ReleaseFast에서
exact path set, root identity와 성공/실패 cleanup을 검증한다. 실제 AppKit/CLI child, leaf/aggregate publication은 후속이다.

U5 baseline-A production runner는 `release_adapter_candidate_baseline_runner.zig`가 final-address candidate/app/workspace/toolchain/source
권위만 빌려 product execution의 닫힌 순서에 실제 두 leaf adapter와 aggregate publisher를 연결한다. caller UUID·digest·profile·성공 bool·
HOME·leaf/evidence pathname 입력은 0이고, 한 absolute deadline을 모든 child와 최종 fence가 공유한다. 성공은 두 leaf와 held aggregate를
caller-owned execution에 보존하고, 실패는 aggregate→signed-app-quit→default-false exact workspace child를 역순 정리하며 cleanup failure의
retry set을 같은 final-address owner에 남긴다. `test-session-host-release-adapter-candidate-baseline-runner`가 copied/pre-owned/alias owner,
authority drift, 순서·deadline, 각 fail-index와 cleanup retry를 Debug·ReleaseFast에서 검증하고, 실제 filesystem 권위·publication은 runner가
호출하는 app/workspace/child/evidence 집중 gate가 각각 소유한다. app/workspace 생성,
artifact attestation, manifest/draft publication과 live workflow 호출은 후속 증거다.

U5 upgrade-B candidate evidence 조립은 `release_adapter_candidate_upgrade_evidence.zig`가 final-address candidate identity와
predecessor identity의 전체 backing authority graph에서만 common·predecessor·signing requirement를 유도한다. 두 최초 view를
fixed snapshot으로 봉인하고 canonical aggregate bind 뒤 output open 직전에 candidate와 authenticated predecessor manifest/file/
download inode를 모두 다시 검증한다. caller identity scalar, copied/pre-owned/alias owner, allocator callback drift, malformed·교환
leaf와 기존 output에서는 publication 0이며 성공은 held output inode authority 하나다.
`test-session-host-release-adapter-candidate-upgrade-evidence`가 이를 Debug·ReleaseFast actual filesystem에서 검증한다. signed leaf
실행, aggregate attestation, manifest/draft publication과 U5 signed frozen 제품 실행은 이 행의 증거가 아니다.

U5 candidate compatibility는 `release_adapter_candidate_compatibility.zig`가 final-address candidate files/product와 held frozen
executable parent authority에서만 canonical compatibility probe를 실행해 frozen SHA·release/source/build identity와 함께 fixed owner에
복사한다. current-manifest 검증과 동일 parser를 공유하고 실행 전후 inode·parent seal·candidate product를 재검증한다. focused gate는
Debug·ReleaseFast에서 copied/pre-owned/alias owner, foreign capture, timeout, malformed/noncanonical output과 executable/parent/candidate
drift의 publication 0을 검증한다. manifest authoring과 signed frozen 제품 실행은 별도 gate다.

U5 Release DMG pathname/mount authority는 **구현**됐다. 종료 gate
`test-session-host-release-adapter-dmg-authority`는 `max_dmg_bytes` 이하 expected size/SHA, exclusive 0700 work-directory,
no-follow source→0600 private DMG bounded streaming copy와 source/copy identity·SHA 결속, read-only fixed mount, exact `Maru.app/Contents/Info.plist` 및
`Maru.app/Contents/MacOS/maru-macos-app` no-follow traversal, Apple transport 전후 mount/product identity 재검증을
Debug·ReleaseFast component 9개로 고정한다. actual-DMG macOS E2E는 성공과 Apple command 실패 모두 captured
`/dev/disk*` identity를 detach하고 private mount/work-directory residue가 0임을 증명한다. 이 gate가 green이어도 GitHub 관측·manifest·attestation·evidence
aggregate의 최종 조립과 release workflow 배선은 별도이며 U5 완료 판정을 바꾸지 않는다.

U5의 non-empty 성공 경로는 trusted run UUID를 `-Dsession-host-release-test-uuid`로 주는
`test-session-host-signed-upgrade`로 자동 실행할 수 있다. 이 opt-in gate는 strict
same-designated-requirement signer인 caller-attested frozen N-1/current executable을 받아 echo를 끈 실제 PTY shell의
pre/post child output, 동일 host/child PID·host/runtime ID, epoch/build 전진과 `committed/none`, capability 유지,
종료 marker 뒤 host-owned reap과 typed inventory 연속 2회 부재를 단언한다. pathname 대신 trusted run UUID, 두 executable
SHA와 signer requirement digest 및 reap 증거를 담은 canonical v2 leaf를 남긴다. 입력의 release
인접성/방향은 executable 내부에서 증명하지 않으므로 release job은
[`maru.session-host-release.v1`](session-host-upgrade.md#u5--제품-활성화)의 exact predecessor·compatibility·서명·asset·attestation
계약을 leaf와 교차검증해야 한다. 실제 배포 artifact A를 보존해 B job에서 A daemon→B adapter→same-PID exec→B GUI
attach를 실행하는 named release gate와 artifact owner가 없으면 provenance 미검증이다.
하네스의 1-runtime 복원 소비자는 GUI 제품 경계인 `RemoteRuntime.attachExisting`이어야 하며, raw MRSH attach만으로는
GUI exact reattach를 주장하지 않는다. 하네스 구현/compile 성공과 실제 signed release artifact 실행 성공은 다른 증거다. 현재 저장소와 일반 CI에는 해당
아티팩트가 없어 후자는 여전히 미검증이며, 위 U5 미완료 판정을 바꾸지 않는다.
near-max gate는 별도 named release step에서 `max_runtime_count - 1` 실제 PTY의 고유 marker, exact typed inventory set,
각 ID의 GUI `RemoteRuntime` 재접속과 전량 reap을 요구한다. 한 runtime 반복이나 codec-only 255-row fixture는 제품 증거가 아니다.
`test-session-host-upgrade-failure-matrix`는 U3 same-PID failure 14개와 U5 zero/non-empty 제품 rollback activation을
한 named entrypoint로 묶고 boundary inventory로 exact 포함을 고정한다. corrupt primary·backup·divergence,
preflight fail/hang, exec 반환, adoption/path identity, 연속 rollback과 promotion failure가 첫 matrix의 범위다.
이는 기존 leaf 증거의 누락 방지와 공통 실행 진입점이며, signed provenance나 아직 연결하지 않은
manifest/socket/FD 전 구간 failure injection을 완료로 승격하지 않는다.
`test-session-host-upgrade-component-failure-matrix`는 그 다음 component inventory로 `handoff_store` 9개,
`exec_fd_set` 6개, `host_authority` 3개, `upgrade_target` 5개를 exact named gate에 묶는다. primary/backup
commit과 residue cleanup, reserved fd slot/CLOEXEC rollback, manifest authority CAS, target staging/pin/path
replacement의 기존 module 증거가 release 검증에서 빠지지 않게 한다. 다만 이것은 component seam의 집합이며
socket/product coordinator를 관통하는 failure injection 증거가 아니므로
manifest/reader/socket/FD/promotion 전 구간 완료 판정을 바꾸지 않는다.
그중 `test-session-host-upgrade-reserved-handoff-failures`는 제품 `commitReserved`의 primary/backup sync,
attempt directory pre/post-readback sync, primary/backup unlink, attempt rmdir, owner sync 여덟 행을 syscall 직전
test-only one-shot seam으로 실패시킨다. 각 행에서 `Pair`가 publish되지 않고 caller의 `Reservation.cancel`이 fd와
owner-pinned attempt residue를 제거하는지 검증한다. 실제 kernel disk fault와 cleanup syscall 연속 실패의
fail-stop 증거는 아니므로 handoff 전 구간 완료 판정을 바꾸지 않는다.
`test-session-host-upgrade-reservation-cleanup-failure`는 reserved primary pathname을 다른 inode로 교체한 뒤
`Reservation.cancel`을 실행해 replacement 보존, `CleanupFailed`, terminal inactive와 original/backup/attempt/owner/readback
fd 전량 회수를 검증한다. boundary inventory는 coordinator가 이 cleanup 오류를 `invariant_violation` 외의 retryable
terminal로 축소하지 못하게 한다. 이 component gate만으로는 실제 outer-loop process fail-stop E2E와 복수 kernel cleanup
syscall fault가 검증되지 않으므로 U5 완료 판정을 바꾸지 않는다.
`test-session-host-upgrade-coordinator-cleanup-fail-stop`은 coordinator-private hook으로 budget reservation 직후
primary identity를 교체해 reserved commit failure와 `Reservation.cancel` failure를 한 actual `processArmed` 호출에서
연속 발생시킨다. 결과는 기존 resumed report가 아니라 `invariant_violation`이어야 하며, 같은 gate의 `upgrade_loop`
exact test가 이를 `fail_stop`으로만 분류한다. public `Context`와 제품 caller는 hook을 보지 않는다. 이 gate만으로는 실제
daemon process의 nonzero exit와 listener/socket closure가 검증되지 않으므로 U5 완료 판정을 바꾸지 않는다.
`test-session-host-upgrade-daemon-cleanup-fail-stop`은 실제 fork daemon에 제품 `Client.prepareUpgrade` 요청을 보내 같은
primary identity 교체를 coordinator까지 관통시킨다. `invariant_violation`→outer-loop `fail_stop`→`ManifestFailed`가
exact child exit 73으로 수렴하고, 기존 sibling의 typed `WriteFailed`, 새 연결의 `EndpointAbsent`, socket과 owner lease
pathname 부재를 deadline 안에 함께 검증한다. fault 선택자는 `builtin.is_test` fixture entrypoint에만 있고 ambient env,
MRSH command, 공개 coordinator `Context`에는 없다. 이로써 단일 실제 pathname identity 충돌의 daemon process E2E는
닫혔지만 disk-full/fsync와 복수 kernel cleanup syscall fault, signed frozen release provenance는 여전히 미검증이므로
U5 완료 판정을 바꾸지 않는다.
`test-session-host-upgrade-kernel-cleanup-faults`는 같은 named gate에 component와 process 증거를 함께 둔다. component는
reserved attempt directory를 실제 read-only mode로 바꾸고 제품 `Reservation.cancel`을 실행해 pinned leaf 제거의
`EACCES`와 non-empty attempt 제거의 `ENOTEMPTY`를 syscall 직후 관측한다. 두 실패가 연속돼도 aggregate
`CleanupFailed`, terminal inactive와 reservation fd 전량 폐쇄여야 한다. process는 같은 filesystem 조건을 test-only typed
fixture로 실제 fork daemon의 제품 `Client.prepareUpgrade` 경로에 만들고 exact `ManifestFailed` exit, 기존 sibling의 typed
폐쇄 실패, listener 재접속 거부, socket/owner lease 부재를 검증한다. process 결과만으로 errno 두 개를 직접 관측했다고
세지 않으며 component의 exact errno와 process의 종료/권위 소멸을 결합한 증거다. ambient env, MRSH command와 공개
coordinator `Context`에는 fault selector가 없어야 한다. 이로써 복수 실제 kernel cleanup syscall fault의 fail-stop은 닫지만
disk-full/fsync, signed frozen release provenance는 여전히 미검증이므로 U5 완료 판정을 바꾸지 않는다.
`test-session-host-upgrade-disk-full-admission`은 user-owned HFS+ disk image의 실제 fork daemon에서 target staging 뒤
coordinator-private typed fixture가 같은 volume을 incompressible bytes로 실제 `ENOSPC`까지 채운 다음 제품
`budget_admission.prepare`를 호출한다. terminal 결과는 quiesce 전 `resumed/state_too_large`여야 한다. accepted drain의
기존 sibling은 typed 폐쇄되고, 새 연결의 같은 PID/listener, `host.info`, exact runtime inventory가 계속 살아 있으며
attempt reservation residue가 없어야 한다.
boundary는 `builtin.is_test` compile guard, ambient env/MRSH test command/public `Context` selector 부재와 fill-before-prepare
순서를 고정한다. 이 gate는 write-side disk-full을 닫지만 ENOSPC 뒤 성공한 fsync를 fault로 오인하지 않으며 delayed fsync
fault와 signed frozen release provenance는 여전히 미검증이므로 U5 완료 판정을 바꾸지 않는다.

모든 단계에서 host crash/SIGKILL 뒤 복구는 비목표지만, upgrade가 시작되기 전·quiesce 중·`exec` syscall 실패·새
binary pre-commit restore 실패는 자동 failure injection으로 구 host 재개 또는 staged rollback을 증명해야 한다.
단, rollback handler 이전 loader/entrypoint crash와 primary+backup handoff 동시 손상은 host crash 비목표다. 최종 자동 gate에는
old-reader primary/backup read-back, staged target preflight reader, target path swap, 8 GiB codec/64 MiB live-store numeric
cap과 cap+1/checked overflow,
secret-bearing handoff unlink-before-exec, pre-exec non-CLOEXEC fd 3+와 target-entry open fd 3+의 exact
allowlist(`primary+backup state`, owner lease, PTY masters), listen/client/wake/trace fd 상속 0, commit에서
state slot close와 master/owner CLOEXEC 복구, `host.v1.json` protocol/build/epoch/lifecycle의
success/rollback 대칭 republish와 경쟁 launcher 0을 포함한다.

### Chrome 상호작용 이관 CIM gate

[Chrome 상호작용 컴포넌트 이관 전략](chrome-interaction-migration.md)의 CIM1 **pure** gate는 충족됐다 —
`chrome/ui/interaction.zig`가 click/hover/focus에 더해 drag 수명(payload·axis·threshold,
began/moved/dropped/cancelled)과 published generation gate를 소유하고, `reconcileCarryingCapture`가
§5 carry verdict를 duplicate·disabled·clip-removed·key mismatch 각각의 cancel과 함께 판정한다.
action ID를 domain intent로 되돌리는 표도 `chrome/ui/intent_table.zig` 하나로 모였고 Session Dock과
archive detail이 그것을 쓴다.

다만 **그 판정을 쓰는 제품 pointer 경로는 아직 없다.** Chrome drag(divider·tab·sidebar
reorder·scrollbar thumb·pane move)의 capture 수명은 여전히 `app_session.zig`의 `PointerGestureOwner`가
소유하며, 첫 소비자는 CIM2다. 그때까지 이 pure gate 통과는 "state machine이 옳다"까지만 주장한다.

다만 §2 판정 순서의 제품 경로 fixture는 이미 있다. 도크 분기가 진행 중인 `PointerGestureOwner`에
양보하도록 고치면서(`6d9c8c59`) 다섯 gesture — divider·Term 탭·pane·사이드바 카드·스크롤바 — 각각을
제품 `mouse()` 경로로 시작해 도크 content 위로 끌고 up하는 회귀 fixture가 `app_session.zig`에 들어갔다.
이것은 제품 경로 fixture이지 pure module gate가 아니므로, 아래 CIM1의 pure 항목을 대신하지 않는다.

이관 순서는 그 문서 §8이 소유하고, 아래는 각 단계가 무엇을 증명해야 완료인지의 단일 출처다.
B1 generic Button 이관이 선행이었고 완료됐다.

| 단계 | 목표 종료 gate | 현재 증거만으로 완료로 보지 않는 것 |
| --- | --- | --- |
| CIM1 interaction adapter | **pure**: `UiPointerEvent`에 published generation 추가, click 수명(`InteractionState`+dispatch/reconcile)을 drag 수명으로 확장(payload·threshold·axis), generic action/drag intent table. §5 `gesture compatibility key` reconcile verdict가 duplicate/disabled/clip-removed/epoch mismatch를 각각 cancel로 판정하고 동일 identity+동일 key에서만 carry한다. **제품 경로 fixture**: §2 판정 순서 — 진행 중 capture가 있으면 pointer가 다른 컴포넌트 rect 위로 가도 소유권이 넘어가지 않고, capture 없을 때만 §4.2 route와 rect 판정이 적용되며, 한 stream이 `InteractionState`와 `PointerGestureOwner`에 동시 진입하지 않는다. **이 항목은 `6d9c8c59`에서 이미 충족됐다**(다섯 gesture 라우팅 fixture) — CIM1은 이를 다시 만들지 않고, 새 권위를 더할 때 같은 fixture를 확장한다 | 상호배제는 `app_session.mouse()`의 분기 순서 문제라 pure module test로 증명할 수 없다. 반대로 그 제품 fixture가 있다고 pure capture/cancel state machine이 검증된 것도 아니다 — 둘은 다른 축이다. pure module 통과만으로 제품 pointer 경로가 이 판정을 실제로 쓴다고 주장하지 않는다. 기존 `PointerGestureOwner` effect path는 이 단계에서 그대로 살아 있다 |
| CIM2 SplitDivider | press/capture/cancel adapter 하나로 이관. split tree removal·resize clamp·WebView divider pass-through의 실제 AppKit E2E. continuous resize가 tick당 최종 좌표 1회로 coalesce되고 같은 clamp 결과에서는 effect를 재실행하지 않음 | headless clamp 계산만으로 PTY resize fan-out과 pane geometry 갱신을 증명하지 않는다. 사이드바 폭·dock outer divider는 별도 variant이므로 pane divider 하나로 divider 축 완료를 주장하지 않는다. **현재 상태**: capture 이관·tick coalescing이 제품 경로에 있고, `macos-divider-smoke`가 실제 `NSEvent`로 divider를 끌어 밴드 존재·drag 중 capture·up 해제·ratio 변화와 **move 수 > resize 수**를 AppKit 경로에서 고정한다. WebView divider pass-through도 같은 스모크가 닫는다 — `window.padding=0` fixture에서 웹뷰가 **실제로 덮은** 밴드 지점을 눌러 `hitTest`가 웹 계층을 돌려주지 않고 divider capture가 서는 것까지 확인한다. headless는 (스케일 × padding) 두 축으로 "밴드가 있거나 divider가 웹뷰 밖이거나 — 어느 쪽이든 잡힌다"를 고정한다 |
| CIM3 [`ScrollArea`](scroll-area.md) | file tree 또는 Session Dock 중 하나를 first consumer로 wheel/thumb/track click/keyboard, scroll anchor, projection/root generation mismatch cancel을 fixture와 capture로 고정. **두 세대가 그대로인 채 track/thumb 기하만 바뀐 경우의 cancel도 별도 fixture로 고정**한다 — carry verdict의 key는 host가 주입한 값의 동등성만 보므로 그것만으로는 이 축이 비고, down 시점 기하로 계산한 스크롤이 손가락과 어긋난다 file tree를 first consumer로 capture 이관·tick coalescing·기하 변경 cancel·wheel/track click/keyboard/scroll anchor를 headless fixture가 고정하고, `macos-scrollbar-smoke`가 thumb 드래그를 실제 `NSEvent`로 흘려 drag 중 capture·up 해제·행 변화와 **move 수 > 재투영 수**를 AppKit 경로에서 고정한다(divider 스모크와 별도 실행 — 도크를 여는 키가 그쪽 창 상태를 바꾼다). coalescing의 소비 지점은 **tick**이다 — `tick`이 divider 것만 소비하고 scrollbar 것을 빠뜨려 thumb을 끄는 동안에는 좌표만 쌓이고 손을 떼야 한 번에 적용되던 것을 고쳤고, `applyPendingScrollbarScroll`을 손으로 부르지 않고 tick만 돌리는 fixture가 그 축을 고정한다 | 한 consumer 통과로 terminal scrollback·selection·mouse mode 우선순위가 함께 증명되지 않는다. terminal scrollbar는 입력 우선순위 축이 달라 별도 gate다. `macos-scrollbar-smoke`는 down·move·up을 **한 tick 안**에서 흘리므로 "up 없이 tick이 적용하는가"를 판정하지 못한다 — 그 축은 headless fixture가 소유한다 |
| CIM4 TabList/Tab | §4.4 provisional live reorder 구현. select/close/overflow scroll/reorder/drop/split/detach와 terminal mouse routing 분리 검증. 복원 트리거(Escape·pointer cancel·window deactivate·modal 진입·source/target tab removal·epoch mismatch)마다 시작 순서 복원과 effect 0을 각각 고정. up commit destination이 up 좌표 재hit-test 결과와 일치. **현재 상태**: terminal tab drag가 `ui/provisional_order.zig`를 소비한다 — drag 중 `pane.terms`·`active_term`은 불변이고, paint(탭 제목·rich cutout·tui 밴드·⌘ 키 힌트 배지)와 hit-test(탭 클릭·rename 대상·파일 드롭 대상·탭 세그먼트 기하·바 스크롤)가 `paneTermOrder`/`paneActiveTermIndex` 한 쌍으로 preview를 함께 읽으며, commit은 소스 바 위 up 한 번이고 그 destination은 **up 좌표의 재hit-test 결과**다(§5 — 마지막 move가 preview에 남긴 자리가 아니다). 드래그 중 pane의 Term 집합이 밖에서 바뀌면(⌘T·close·in-place 교체) provisional을 재봉합하지 않고 폐기한다 — `tick`의 집합 검사와 `destroyTerm` barrier 두 곳이 그 자리이며, 후자가 없으면 preview에 남은 `*Term`이 해제된 뒤에도 paint에 실린다. 복원 트리거는 Escape(키 소비)·새 primary down·window deactivate·모달 진입(tick의 `anyModalOverlayOpen` 게이트)·Term removal 다섯이 각각 fixture로 고정돼 있고, `macos-tab-drag-smoke`가 실제 `NSEvent`로 탭을 끌어 **drag 중 보이는 순서와 model이 갈렸다가 up에서 합쳐지는 것**·Escape 복원·down~up 사이에만 capture가 사는 것을 AppKit 경로에서 고정한다(divider·scrollbar 스모크와 별도 실행 — 그쪽이 split·도크로 창 상태를 바꾼다). 비-모달 notice 토스트는 트리거가 **아니다** — 비동기로 뜨는 토스트로 취소하면 사용자가 하던 재정렬이 배경 이벤트에 파기된다. 그것이 up을 가로막던 문제는 `mouse()`의 **라우팅 순서**가 없앤다: 진행 중인 제스처의 move/up이 오버레이 블록보다 먼저 처리되므로 어떤 오버레이도 up을 삼키지 못하고, 토스트도 사용자가 읽을 때까지 살아 있다. 드래그는 primary 버튼에서만 arm·commit된다(다른 버튼의 up이 재정렬을 확정하던 경로 차단). Escape는 제스처가 살아 있으면 소비하고 취소한다 — "움직였을 때만"으로 좁히면 끌었다 제자리로 돌아온 드래그에서 취소도 안 되고 ESC가 터미널로 새어 사용자가 취소된 줄 알고 손을 떼는 사이 up이 commit한다. **남은 몫**: select/close/overflow scroll/detach와 terminal mouse routing의 분리 검증. epoch mismatch 축은 이 단계 밖이다 — published generation gate는 `chrome_host.interaction`(CIM1)이 소유하고 `terminal_tab`은 아직 legacy pointer-gesture payload라 epoch를 갖지 않는다. 그 축은 tab select/close가 `InteractionState`로 이관될 때 함께 열린다 | 제품 동작을 영구 live reorder에서 바꾸는 변경이므로 fixture 갱신 없이 완료로 표시하지 않는다. drag 중 외부 tab 집합 변경(단축키 close·원격 관측의 Term 소멸)의 폐기·복원 경로가 없으면 부분 이관이다. AppKit cancel 이벤트는 ABI mouse kind(1~5)에 없으므로 "pointer cancel"은 새 primary down 경로로만 검증된다 |
| CIM5 Reorderable Sidebar | row geometry와 drag preview/cancel만 common capability로 이관하고 group·pin·agent-row model은 domain 유지. armed→dragging threshold 전 click 보존, marker/slot 무결성 | 카드 reorder 통과만으로 헤더 아이콘 hit-test와 검색 blur가 키 포커스를 터미널로 되돌리는 규율이 증명되지 않는다 |
| CIM6 Input/overlay composite | 한 consumer의 기존 keyboard/Escape/focus 계약을 `Input`/`Menu`/`Popover`/`Dialog` props로 명시하고 그 consumer의 실제 host E2E | AppKit first responder·IME·native accessibility는 headless pointer fixture로 증명할 수 없다. 실제 host E2E 또는 명시된 수동 검증 결과가 없으면 완료가 아니다. 주소창 caret/selection은 [텍스트 필드 에디터](text-field-editor.md) 범위이며 이 단계가 흡수하지 않는다 |

모든 CIM PR의 공통 산출물은 clip/hit rect/action ID/snapshot generation과 final allocation/worker
pending의 structured summary, 그리고 제품 Metal PNG + JSON readback이다. 현재
`macos-chrome-lab-smoke`가 받는 축은 scenario와 font뿐이고 render scale 축은 없다
(`macos-chrome-lab-font-review`의 `-review-2x.png`는 ffmpeg nearest-neighbor 확대본이지 2× backing
scale 렌더가 아니다). render scale 1×/2× 비교가 필요한 consumer는
[Metal UI 레이아웃·컴포넌트 시스템](metal-ui-layout.md)의 scale-normalized rect gate를 쓰거나, 그 PR이
Chrome Lab 도구 확장을 자기 범위로 선언한다.

`PointerGestureOwner` union에서 **`address_selection`을 제외한** variant를 전부 소진하기 전에는
interaction 이관 전체를 완료로 표시하지 않는다. 한 consumer가 새 tree를 쓴다는 사실은 그 consumer의
부분 이관 증거일 뿐이다. `address_selection`이 예외인 근거와 그 variant의 존속 사유는
[Chrome 상호작용 컴포넌트 이관 전략](chrome-interaction-migration.md) §2가 단일 출처다 — 여기서
"`none`만 남는다"로 적으면 도달 불가능한 gate가 된다.

## 구현 전 TDD 절단 원칙

세션 컨트롤 플레인과 웹 패널은 [control-plane-implementation.md](control-plane-implementation.md) §11의 micro-slice를 기본 구현 단위로 삼는다. Phase 1~7은 제품 milestone이고, 구현 PR 하나가 통째로 한 Phase를 끝내는 것을 기본값으로 보지 않는다.

- 각 micro-slice는 먼저 실패하는 단위/fixture/통합 테스트 또는 spike artifact를 만든 뒤 구현한다.
- 새 capability, transport, CLI 명령, WebView bridge, sanitizer, WebDriver endpoint는 parser/authz/help/docs가 같은 micro-slice 안에서 닫혀야 한다.
- 자동화가 어려운 GUI/IME/z-order/공증류는 spike 결과를 artifact로 남기고, 그중 자동화 가능한 계약(frame/NSView 계층 값, 권한 판정, 경로 정규화, sanitizer 결과 등)을 최소 회귀 테스트로 고정한다.
- 여러 micro-slice를 한 PR에 묶을 수는 있지만, 같은 harness를 공유해 더 작게 리뷰·rollback된다는 근거와 각 slice의 red→green 결과를 PR 본문에 남긴다.
- 이전 micro-slice의 종료 gate가 깨지면 다음 slice를 진행하지 않는다.

## 안정성·성능 진행 원칙

각 구현 PR은 기능 검증과 별도로 안정성·성능 영향을 분류해야 한다. 분류는 PR 본문에 남긴다.

- **hot path 영향 있음**: frame tick, PTY pump, renderer, socket dispatch, queue/backpressure, capture/stream, WebView bridge, build/watch loop를 건드리면 `performance-budget.md`의 관련 항목 또는 새 lightweight artifact를 연결한다.
- **bounded 증명 필요**: 새 queue, buffer, chunk, cache, background task는 size limit, TTL/revocation, drop/coalesce, slow-consumer 처리, cleanup/rollback 경로를 테스트한다.
- **전후 비교 필요**: 기존 perf/stress 항목이 있으면 변경 전후를 비교한다. 숫자가 흔들리는 GUI 영역은 wall-clock 대신 결정적 artifact(frame 값, event count, dropped count, queue depth, copy bytes)를 남긴다.
- **예산 부재 시**: "성능 영향 없음"으로 쓰지 않는다. 아직 예산이 없다고 적고, 어떤 metric을 다음에 추가할지 [성능 예산](performance-budget.md)에 연결한다.
- **퇴행 시 중단**: 기능 테스트가 통과해도 안정성·성능 gate가 깨지면 다음 micro-slice를 진행하지 않는다.

### 영속 host CR 실행 중 transport reconnect gate

**상태: 부분 구현(CR0a·CR3a·CR3b R1·R2a·R2b·R2c·R3 완료).** `RemoteRuntime`/Surface/pump/routing 주소를 고정한 stable shell과 generation bundle,
stable `ScreenSource` borrow, 앱 전역 host job, existing-host-only controller recovery를
[persistent-session-host.md](persistent-session-host.md#실행-중-connection-invalidation과-재연결)가 소유한다. raw in-place
field 재초기화와 whole-runtime GUI pointer 교체는 허용하지 않는다.

- CR0a(구현): raw `failClosed`와 내부 `invalidateConnection*` 직접 callsite 0, semantic `Outcome`과 connection-fatal
  `ConnectionReason`의 타입 분리, typed tuple exhaustive golden table, expected/unexpected 분류와 최초 reason 불변을
  production connection-fatal `Client`/`RemoteRuntime`/`RemoteAttachment` callsite에 적용했다. semantic `Outcome` 4종은
  model-only이고 실제 semantic decode/dispatch 연결·scope 축소는 CR1이다. Client source/adoption/projection seal이 reason을
  포함하며 clean EOF·read timeout/failure·framing truncation/malformed·write progress ambiguity/known partial·attachment
  cleanup의 타입을 테스트한다. `zig build test-session-host`와 `mise run check-boundaries`가 증거다. incident
  artifact/reconnect 동작은 주장하지 않는다.
- CR0b: pointer-free exact-208 DTO와 256-byte envelope, closed `SourceSite`, process/fork/sequence authority, first-reason과 incident의
  단일 publication suffix, 120 incident+8 aggregate exact-32 KiB ring, child-event correlation, redaction, ring handoff→reconnect와
  bounded disk writer ordering, blocked/late writer, ring full/other-bucket saturation과 Debug fail-stop.
  첫 RED gate `zig build test-session-host-cr0b`는 CR3b R1을 상속하고 실제 fork-before-lock 거부와 동시 sequence 유일성을 포함한
  중립 schema/codec/ring/service component 20개와 boundary 1개를 Debug·ReleaseFast에서 exact-count한다. 두 번째 중립 gate는
  pointer-free writer handoff, lowest-bit value-copy, stale aggregate generation requeue, exact completion/replay·foreign authority
  거부를 component 11개로 고정한다. 세 번째 storage gate는 strict detail/aggregate filename, final-address 0700 directory FD,
  0600 no-follow exclusive create, exact-content idempotence/collision 보존과 1 MiB oldest-first prune를 component 6개로 고정한다.
  세 component군과 boundary 1개를 Debug·ReleaseFast에서 실행한다. process bootstrap/writer thread/Client publication은 후속
  CR0b gate가 닫기 전 구현 완료로 세지 않는다.
  네 번째 runtime gate는 final-address heap owner, exact 한 writer, nonblocking wake coalescing, lowest-bit drain, disk 실패 뒤 ring 보존,
  clean join·timeout detach와 writer failure 뒤 degraded join, stopping clock/poll 실패 뒤 degraded detach/backing 보존,
  fork-before-pipe 거부, aggregate issuer exhaustion의 실제 runtime fatal leaf를
  Debug·ReleaseFast component 7개와 실제 daemon bootstrap boundary로 고정한다. process bootstrap과 writer thread는 구현됐으며 Client incident publication은 후속 CR0b gate 전까지 부분 구현이다.
  최초 suffix 선행 substrate 5개는 service mutex 아래 모든 fallible ring plan을 준비하고 evidence commit 뒤에도 pending bit을 숨기며,
  pristine abort/reuse와 service alias·copied/plan/seal drift·evidence 이후 abort 거부 및 pending exact-once publication을
  Debug·ReleaseFast exact-count로 검증한다. public prepared DTO는 재귀 pointer 0이다. 네 단계 API는 같은 모듈의 기존 compatibility
  `publish` wrapper가 각각 exact 1회 호출하지만 외부/platform 제품 caller는 아직 0이다. proof drift의 common fatal provenance와 Client id/key/reason publication은
  아래 suffix 10 및 subprocess 4가 소유하므로 이 5개만으로 여섯 번째 gate나 CR0b 완료를 주장하지 않는다.
  다섯 번째 Client publication gate는 `HostPool.prepareManagedOwnedPublication -> HostAdapter.initManagedInPlace ->
  ClientSlot.initManagedInPlace -> HostPool.commitOwnedPublication`의 실제 제품 순서를 고정한다. neutral binding/permit 6개,
  HostPool reservation·generation·capacity·copy/replay·capacity OOM 원복·보호 범위 alias·copied pool 거부·managed source alias 11개, final-address ClientSlot binding 7개, AppSession current/restore 공용 publication leaf
  publication leaf scenario 4개와 HostPool capacity OOM 1개, boundary 1개를 Debug·ReleaseFast에서 exact-count한다. 제품 `HostPool.addOwned` caller 0,
  HostPool의 Client import/역참조 0, map publication 뒤 binding store 0, binding publication 뒤 fallible/callback 0을 함께 검증한다.
  이 gate는 binding publication, suffix가 소비할 pointer-free `IncidentInput`·`PreparedManagedPoison`·`ReconnectAdmission`·`IncidentRepeatKey`와 canonical service record·input digest·aggregate fingerprint 계약 7개,
  held Client operation의 `id -> key -> reason` publication, owner-storage alias 거부, copied/bind drift 회수와 managed request의
  Client-owned canonical projection prerequisite 5개만 닫으며
  first-reason+incident 단일 poison suffix는 여섯 번째 gate가 닫기 전 구현 완료로 세지 않는다.
  composite coordinator 선행 gate 6개는 실제 managed ClientSlot·publisher Registry·ConnectionIncidentRuntime/service를 함께 사용한다.
  `CR0b composite coordinator는 Client operation publisher lease service lock 순서로 first를 준비한다`,
  `CR0b composite coordinator는 service prepare 실패를 publisher와 Client operation 역순으로 회수한다`,
  `CR0b composite coordinator는 bind drift를 service abort publisher release Client release 역순으로 회수한다`,
  `CR0b composite coordinator는 ring id key reason pending wake lease operation 순서로 first를 게시한다`,
  `CR0b composite coordinator는 같은 fingerprint repeat에서 first Client 필드와 sequence를 보존하고 aggregate만 갱신한다`,
  `CR0b composite coordinator는 다른 fingerprint repeat를 mutation 없이 거부하고 first 권위를 보존한다`를 Debug·ReleaseFast exact 6으로
  실행한다. 여섯 행 모두 제품 owner를 실제 조합한다. 첫 행은 `client held -> publisher acquired -> runtime projection validated -> service prepared -> client bound -> composite held`,
  둘째는 service가 lock을 얻기 전 실패 뒤 `publisher released -> client released`, 셋째는 실제 binding validator 실패 뒤
  `service aborted -> publisher released -> client released`, 넷째는 coordinator의 `ring evidence -> client committed -> pending unlock -> wake outcome ->
  publisher release -> client operation release` transcript와 Client operation prerequisite의 별도 `id -> key -> reason` store oracle을 함께 요구한다. 실패 행은 ring/pending/Client first fields 0,
  mutex 재획득, active lease 0, 같은 node operation 재사용을 함께 검증한다. repeat 두 행은 same-fingerprint aggregate-only 성공과
  fingerprint mismatch의 ring/pending/Client mutation 0을 고정한다. 이 6개는 composite prerequisite일 뿐 suffix 10·managed caller 6 완료로 세지 않는다.
  publisher authority 7개와 exhaustion child 1개는 canonical child artifact 경로를 주입하는 CR0b 전용 runner에서만 완료 증거가 된다.
  일반 aggregate에서는 두 exhaustion entry가 의도적으로 skip되므로 aggregate green을 이 fail-stop 증거로 대체하지 않는다.
  별도 GUI incident owner prerequisite 4개는 final-address runtime+registry 설치, current/restore 역할의 동일 owner 재사용,
  copied owner·process/app nonce 교체 거부를 닫는다. allocator/create 실패는 whole owner pristine rollback과 같은 owner 재사용을,
  active lease가 있는 shutdown은 closing owner/runtime 보존과 lease release 뒤 same-owner joined retry, 200 ms deadline의 detached
  backing 보존을 검증한다. 이는 실제 AppHost callback/outcome matrix인 bootstrap 5와는 별도 선행 증거다. 실제 AppSession
  current-first, restore-first→current, multi-window 제품 entrypoint 3개와 조기·foreign ABI mutation 0 및 joined/replay,
  runtime failure의 degraded/replay와 active-lease timeout detached/replay prerequisite 3개는
  managed adapter 연결 전에 이 owner를 설치·정산하는 별도 GUI gate로 실행한다.
  daemon bootstrap prerequisite 1개는 실제 제품 bootstrap leaf로 daemon PID, process/service nonce, runtime/service generation,
  최초 sequence 0과 unpublished joined 정산을 검증한다. pointer-free fixed-64 transcript 계약 1개는 두 child 비교에 필요한
  PID/nonces/generations/sequence scalar 및 closed GUI/daemon role·zero reserved만 허용한다. bootstrap 4는 서로 다른 canonical artifact인 dedicated GUI child(actual 4: named 1+root/import sentinel 3)와
  daemon child(actual 1)를 fresh exec하고, exact 64-byte transcript·EOF·exit 0을 child별 2초 absolute watchdog으로 회수한다.
  두 transcript의 PID/process nonce/service nonce/app-instance nonce가 모두 다르고 양쪽 최초 sequence가 0임을 실제 비교한다.
  runtime 수명 prerequisite 7개는 clean `joined|detached`와 `degraded_joined|degraded_detached`를 구분하며 writer failure 뒤
  정상 join도 degraded provenance를 보존한다. stopping 이후 injected clock 실패와 실제 completion poll 오류는 backing을 보존하는
  degraded detach로 닫는다.
  여섯 번째 Client poison publication gate는 아래 32개 unique component와 boundary 1개, 총 33개를 Debug·ReleaseFast에서
  exact-count한다. 각 행은 제품 API를 직접 실행하며 같은 fixture helper의 별칭으로 개수를 채우지 않는다.

  | owner | exact test name |
  | --- | --- |
  | authority 1 | `CR0b publisher authority는 final address에 등록하고 lease를 조회한다` |
  | authority 2 | `CR0b publisher authority는 copied moved owner를 mutation 없이 거부한다` |
  | authority 3 | `CR0b publisher authority는 fork PID를 lock 전에 거부한다` |
  | authority 4 | `CR0b publisher authority는 runtime service address와 generation splice를 거부한다` |
  | authority 5 | `CR0b publisher lease는 replay와 double release를 거부한다` |
  | authority 6 | `CR0b publisher registry는 canonical owner를 재사용하고 second owner 교체를 거부한다` |
  | authority 7 | `CR0b publisher authority generation exhaustion은 publication 전에 fail-stop한다` |
  | suffix 1 | `CR0b 최초 poison은 ring id key reason 순서와 reconnect admission을 고정한다` |
  | suffix 2 | `CR0b repeat poison은 first id와 detail sequence를 보존하고 aggregate를 한 번 증가시킨다` |
  | suffix 3 | `CR0b 다른 fingerprint repeat는 mutation 없이 거부하고 first key와 reason을 보존한다` |
  | suffix 4 | `CR0b ring full poison은 detail drop 뒤에도 nonzero correlation을 게시한다` |
  | suffix 5 | `CR0b poison prepare는 binding splice를 mutation 없이 거부한다` |
  | suffix 6 | `CR0b poison prepare는 input source outbound closed case drift를 mutation 없이 거부한다` |
  | suffix 7 | `CR0b repeat key는 copy splice replay를 모두 거부한다` |
  | suffix 8 | `CR0b poison clock은 failure negative timestamp와 min max reorder를 닫는다` |
  | suffix 9 | `CR0b wake degraded는 committed publication을 보존하고 재시도하지 않는다` |
  | suffix 10 | `CR0b poison callback reentry는 Busy이고 Client와 ring을 바꾸지 않는다` |
  | caller 1 | `CR0b managed public poison은 canonical suffix만 호출한다` |
  | caller 2 | `CR0b prepared execution poison은 held operation suffix를 호출한다` |
  | caller 3 | `CR0b registered operation deferred poison은 canonical suffix를 호출한다` |
  | caller 4 | `CR0b allocator callback deferred poison은 canonical suffix를 호출한다` |
  | caller 5 | `CR0b actual read event pump poison은 canonical suffix를 호출한다` |
  | caller 6 | `CR0b actual outbound RPC ambiguity는 canonical suffix를 호출한다` |
  | bootstrap 1 | `CR0b GUI current first는 managed adapter 전에 process owner를 한 번 설치한다` |
  | bootstrap 2 | `CR0b GUI restore first 뒤 current는 같은 process owner를 쓴다` |
  | bootstrap 3 | `CR0b GUI multiple window와 adapter는 process owner를 재사용한다` |
  | bootstrap 4 | `CR0b daemon bootstrap은 GUI와 독립된 nonce와 sequence owner를 설치한다` |
  | bootstrap 5 | `CR0b AppHost termination은 revoke drain bounded shutdown을 한 번 수행한다` |
  | subprocess 1 | `CR0b subprocess는 copied fork authority를 service 전에 거부한다` |
  | subprocess 2 | `CR0b subprocess는 authority service seal splice를 common fatal로 닫는다` |
  | subprocess 3 | `CR0b subprocess는 ring id key reason 중간 drift를 common fatal로 닫는다` |
  | subprocess 4 | `CR0b subprocess는 optimize mode별 unexpected poison 결과를 고정한다` |

  suffix 1은 ring/id/key 각 중간 stage의 실제 reconnect-admission probe가 0이고 reason store 뒤 exact 1임을 검증한다. 모든 이름의
  conjunction과 matrix는 closed case table과 exact executed-case count를 함께 assert한다. subprocess 3은 ring/id/key/reason 각 drift
  injection stage의 distinct marker와 exact 4행을 고정한다. caller 2~6은 공용 facade를 직접 부르지 않고 이름에
  적힌 실제 제품 trigger를 실행하며 boundary가 각 ingress의 canonical suffix caller exact 1과 reason-only caller 0을 고정한다.
  bootstrap 1~3은 실제 AppSession current/restore/multi-window entrypoint를 실행한다. bootstrap 4는 dedicated GUI child와 daemon
  child의 실제 bootstrap transcript를 함께 비교해 PID/process nonce/service nonce/첫 sequence domain 비공유를 증명한다. bootstrap 5는
  실제 AppHost termination entrypoint transcript로 ordinary Window/AppSession deinit의 revoke/shutdown/writer join 0, 마지막 AppSession
  shutdown 전 incident ABI 0, 모든 remote backend close/detach settlement 전 ABI 0, 둘 모두 완료 뒤 exported AppHost ABI exact 1과
  closed outcome을 검증한다. GUI process owner는 첫 managed adapter보다 먼저 설치되고 restore-first/current-first가
  공유한다. managed reason-only caller 0, product runtime direct import 0, product shutdown caller exact AppHost 1+daemon 1을 함께 검증한다.
  subprocess 4개는 모두 dedicated fresh child, fixed marker transcript, exact exit/signal·EOF, 2초 absolute watchdog을 사용한다. 마지막
  행은 Debug에서 exact `commit -> wake outcome -> publisher lease release -> common fatal _exit(86)` marker와 final lease count 0을,
  ReleaseFast에서 같은 commit/wake/release evidence 뒤 scheduler continuation exact success를 요구하며
  optimize-mode skip은 허용하지 않는다.

  현재 별도 managed public poison caller 1 gate는 caller가 closed reason/source/controller generation만 제출하고 app-process owner clock과
  registered Client pin이 binding, parser/outbound phase, last successful request, queue/count/upgrade 상태를 canonical `IncidentInput`으로
  투영한 뒤 final-address HostAdapter와 app-global publisher owner를 실제 조합한다. held Client 상태로 first/repeat를 선택하고 first의
  terminalization·fd close·reconnect admission, repeat의 admission 0까지 실행한다. 실제 scheduler consumer는
  아직 후속 gate 범위이며 caller 1 green만으로 전체 제품 ingress 완료를 주장하지 않는다.
  caller 2 gate는 actual generation prepared execution이 app-process owner의 sealed timestamp receipt를 먼저 받고, registered operation
  아래 stack-local poison capture와 `PreparedManagedPoison`을 완성한 뒤 operation release 후 process publication port로 게시하는 경로를
  소유한다. response/transport failure 중간에는 first reason·fd·pending outbound·ring·admission이 0이고, 최종 publication은 caller 1과
  동일한 canonical suffix를 exact 1회 사용해야 한다. `GenerationAttachment`·`RemoteRuntime`의 publisher/registry/runtime pointer 저장,
  managed product reason-only poison, operation 안 coordinator 재진입은 모두 0이다. actual socket EOF가 이 경로를 통과해 canonical
  first incident, terminal fd close와 reconnect admission을 게시하고 Debug·ReleaseFast exact 1로 실행한다.
  caller 3 gate는 actual generation event take가 registered operation 진입 전에 같은 sealed timestamp receipt를 받고, validation 뒤
  corruption을 operation-bound caller-final capture에만 기록한다. Client first reason·fd·ring·admission은 operation 반환까지 0이며,
  `RemoteRuntime` 제품 drain이 반환된 pointer-free handoff를 같은 publication port에 exact 1회 제출해 canonical first incident,
  terminal fd close와 reconnect admission을 게시한다. event transport/attachment에는 publisher pointer를 저장하지 않는다.
  caller 4 gate는 actual generation RPC response allocation의 checked allocator callback이 active prepared-execution lease 아래
  `Client.poison(.local_resource_exhausted)`을 호출하는 제품 trigger를 실행한다. callback은 public mutation fence나 coordinator를
  재진입하지 않고 caller 2의 sealed stack capture에 reason과 `SourceSite.client_cleanup`만 한 번 기록하며, callback 중 Client
  first reason·usable/fd와 ring/pending/admission은 그대로다. response allocation failure의 일반 cleanup이 같은 reason을 다시
  관측해도 최초 allocator source를 보존하고, registered operation release 뒤 기존 publication port가 canonical first incident,
  terminal fd close와 reconnect admission을 exact 1회 게시한다. allocator와 attachment/runtime에는 publisher pointer를 저장하지 않는다.
  caller 5 gate는 actual generation `RemoteRuntime.pumpDelta`가 첫 event/screen read 전 final batch adapter와 ClientSlot에
  caller-final capture를 결속한 뒤 socket EOF를 읽는 제품 pump 전체를 실행한다. read callback 안에서는 caller-final capture에
  별도 presence bit와 `connection_eof`가 기록되고(raw 0을 absence로 해석하지 않음) Client first reason·usable/fd,
  batch registry, ring/pending/admission은 mutation 0이다. batch reservation·allocator scope·RemoteAttachment callback과 public mutation
  fence가 모두 unwind된 뒤 publication port가 `SourceSite.client_read` canonical first incident, terminal fd close, reconnect admission을
  exact 1회 게시한다. error tag를 reason으로 재분류하거나 batch adapter/runtime에 publisher pointer를 저장하지 않는다.
  caller 6 gate는 actual generation `RemoteRuntime.resize`가 pre-existing 1 MiB pending outbound를 nonblocking socket에 부분 전송한 뒤
  `EAGAIN`으로 `outbound_write_ambiguous`를 확정하는 제품 ingress를 실행한다. execution lease 아래 caller-final handoff에는
  `SourceSite.client_response`, pending request 1, partial outbound의 실제 nonzero offset·전체 length·남은 queue bytes를 Client-owned
  snapshot으로 봉인하고, pre-publication 시점의 first reason·usable/fd·pending outbound·ring/pending/admission은 mutation 0이다.
  publication scope와 execution lease, registered operation을 모두 정산한 뒤 기존 publication port가 canonical first incident,
  terminal fd close·pending outbound 회수와 reconnect admission을 exact 1회 게시한다. write error tag 재분류나 operation 안
  coordinator 재진입은 0이다.
  선행 publication-port substrate는 GUI owner bootstrap 성공 뒤 final owner 주소만 keyed seal로 게시하고, current owner thread의 timestamp
  조회만 허용하며 foreign thread와 termination revoke 뒤 조회를 graph 역참조 전에 거부한다. raw registry/runtime pointer는 port에 없다.
  reconnect admission owner prerequisite 2개는 fixed-cap 64 inline final-address row와 pointer-free projection으로 first reconnect
  event의 exact-once admit/consume, duplicate generation·repeat·no-retry mutation 0을 닫는다. app-process publication owner가 admission
  capacity를 publication 전에 preflight하고 first publication·terminalization·fd close 뒤 no-fail admit한다. repeat는 admission을 늘리지 않는다.

  32개 component count와 아래 내부 공격 행 count는 별도다. 복합 component의 closed table은 exact 다음 행만 포함한다:

  | component | exact 내부 행 |
  | --- | --- |
  | authority 2 | copy, move = 2 |
  | authority 4 | runtime address, service address, runtime generation, service generation = 4 |
  | authority 5 | copied lease, replayed lease, double release = 3 |
  | authority 6 | same-owner idempotent reuse, second-owner address, second-owner generation = 3 |
  | suffix 6 | source-site raw, parser phase, outbound phase, outbound offset/length, request count, stream count, event count, queue count/bytes, input digest = 10 |
  | suffix 7 | copied key, client-address splice, first-id splice, fingerprint splice, binding-seal splice, replay after connection generation = 6 |
  | suffix 8 | clock error, negative timestamp, earlier repeat min, later repeat max = 4 |
  | bootstrap 5 | ordinary Window/AppSession deinit shutdown 0, last AppSession 전 incident ABI 0, backend settlement 전 incident ABI 0, session shutdown 뒤 backend settlement ABI 1, 모두 완료 뒤 incident ABI 1, inactive outcome, joined outcome, active-lease timeout detached outcome, runtime shutdown error degraded outcome, ABI replay inactive = 10 |
  | subprocess 1 | copied authority, fork authority = 2 |
  | subprocess 2 | authority seal, service seal = 2 |
  | subprocess 3 | ring, first id, repeat key, first reason = 4 |
  | subprocess 4 | Debug evidence 뒤 common fatal `_exit(86)`, ReleaseFast evidence 뒤 scheduler success = optimize mode별 1 |

  bootstrap 5 prerequisite의 joined 행은 빈 shell이 아니라 owned HostAdapter/Client row가 있는 실제 HostPool을 정산한다.
  settlement preflight는 실제 AppSession init/deinit이 소유하는 live-session counter와 backend의 residual runtime·reservation·close operation·close sweep를 각각
  `.inactive`로 거부하고 backend/pool/incident owner를 보존한 뒤, blocker 원복 후 같은 제품 leaf가 `.settled`로 수렴해야 한다.
  AppSession publication prerequisite는 current/restore 제품 caller가 공유하는 singleton claim leaf를 실제 created-pool과
  existing-pool sibling topology로 실행한다. claim 경쟁 실패는 새 backend를 먼저 정산하고, created pool은 전체 회수하며,
  existing pool은 기존 sibling을 보존한 채 실패한 신규 row와 그 row의 spawn-host 선택을 함께 제거해야 한다.
  이 gate가 green이 되기 전 CR0b를 구현 완료로 세지 않는다.
- CR1: `zig build test-session-host-cr1`이 CR0b actual caller gate를 상속하고 production-type scheduler admission 4개와 boundary 1개를
  Debug·ReleaseFast에서 exact-count한다. 기존 `client_poison` production decision이 bounded semantic 오류를 stream scope·usable
  transport로 유지하고 CR1 owner가 admission 0/idle임을 결합한다. CR0b actual ingress는 partial read/write admission 생성을 소유하고,
  CR1 fixture는 그 동일 production DTO를 scheduler owner에 넣어 sealed dispatch를 exact 한 번 claim해 같은 inline row를
  `.scheduled` job으로 전환한다. 실제 writer failure의 `wake=degraded`도 disk completion을 기다리거나 publication을
  재시도하지 않고 동일 scheduled outcome으로 끝난다. closed transition table은 `scheduled|retry_later|discarded_stale` exact 3이며,
  retry는 row 보존+새 attempt generation, copied/moved/wrong-thread/replay는 mutation 0을 검증한다. stale 제품 정산 caller는
  canonical HostPool/ClientSlot generation projection이 생기는 CR3b/CR5 전까지 0이고 이 gate에서는 model-only transition으로만
  고정한다. `runOnce` 제품 caller도 CR5 coordinator 전까지 0이다. 증거 수준은 production-type unit이며 host connect/runtime
  generation publish는 0이다.

  | CR1 owner | exact test name |
  | --- | --- |
  | scheduler 1 | `CR1 bounded semantic 오류는 reconnect admission을 만들지 않는다` |
  | scheduler 2 | `CR1 partial read와 write는 sealed dispatch를 exact once schedule한다` |
  | scheduler 3 | `CR1 artifact degraded는 disk를 기다리지 않고 dispatch를 schedule한다` |
  | scheduler 4 | `CR1 scheduler dispatch는 retry stale copy replay를 closed transition으로 정산한다` |
- CR2a: `zig build test-session-host-cr2a`가 CR1을 상속하고 Debug·ReleaseFast에서 `RemoteGeneration` production-type test 2개와
  source boundary 1개를 exact-count한다. field inventory는 generation-owned 12개만 허용하고 allocator/io/runtime ID, Surface,
  direct-input/control queue, pending/close/lifetime owner가 bundle로 섞이면 RED다. extraction parity는 distinct nonzero fixture와
  existing runtime tests를 결합해 connection/attachment/screen, event tracking, resize state, pump state, raw observation의 값과
  allocator-backed ownership/deinit 결과가 중첩 전후 동일하고 nested 정렬 증가가 Debug/ReleaseFast exact 16바이트
  (4,096 runtime에서 64 KiB)임을 검증한다. CR2a는 proxy, InputOwner, reconnect publish와 제품
  generation 교체 caller를 추가하지 않는다.
- CR2b: `zig build test-session-host-cr2b`가 CR2a를 상속하고 Debug·ReleaseFast에서 stable proxy test 6개, actual runtime wiring
  test 1개와 source boundary 1개를 exact-count한다. final-address `ScreenSource`가 bounded unavailable target에서 시작하고 actual attach가
  같은 proxy에 live screen을 게시한다. reader는 exact `{generation,target}`을 pin해 current를 다시 읽지 않고 unlock하며,
  nested lock은 blocking 전에 거부한다. writer-pending 뒤 late reader는 기존 reader보다 먼저 들어가지 못하고, publish/close는
  기존 borrow 반환 뒤에만 retired live target을 돌려준다. render critical section과 writer wait는 count·total·max ns로 계측한다.
  zero/stale/skip/max generation과 copied final owner·foreign writer는 fail-close하고,
  detach/deinit은 proxy close 뒤 attachment screen을 파괴한다. 실제 socket reconnect와 `RemoteGeneration` swap/reclaim은 아직
  CR2e/CR4 범위다.
- CR2c: `zig build test-session-host-cr2c`가 CR2b를 상속하고 Debug·ReleaseFast에서 neutral `InputOwner` 3개,
  `TermRuntimeBackend` handle 결속 1개, local backend parity 1개(root/import sentinel 7개 포함 app artifact 실제 12회),
  remote backend parity 1개와 source boundary 1개를 exact-count한다.
  blocking bytes, nonblocking partial progress/error, `CoreCommand`가 같은 opaque handle과 기존 backend leaf로 전달되며
  local/remote `TermRuntimeBackend` 함수표가 facade를 구현함을 고정한다. queue/epoch/sequence/paused paste storage와
  `RemoteRuntime`의 기존 direct-input/control field·동작은 이 단계에서 바뀌지 않고 제품 facade caller는 0이다.
  CR2d1: remote paste·IME 확정·OSC52 응답은 `InputOwner.enqueueBatch`로 stable runtime owner에 직접 들어간다.
  closed kind와 nonzero epoch/checked sequence, IME commit+replay atomicity, LF→CR, cap/OOM/sequence 실패 mutation 0,
  blocked-wire retained queue와 eventual ordered wire golden trace, remote `AppSession.pending_pastes` entry 0을
  Debug·ReleaseFast에서 고정한다.
  local은 `caller_owned`로 기존 queue 의미가 변하지 않는다. CR2d2는 remote blocking key, paste-family batch,
  scroll-to-bottom, core-command를 closed six-kind record와 한 epoch/checked sequence에 합치고, blocked wire에서
  `key -> paste -> scroll -> key -> scroll -> core-command` transcript와 같은 physical frame 순서, sequence exhaustion
  mutation 0, byte/control 순차 retire, control transcript drift의 wire 전 거부를 Debug·ReleaseFast에서 고정한다. 기존 direct-input/control barrier와
  `writeNonBlocking` partial 의미는 유지한다. CR2d3은 stable shell의 observer-generation baseline과 BEL/OSC52 cursor를
  고정한다. 첫 관측·generation 교체·counter 감소는 재생 0, write RPC 실패는 cursor mutation 0, 성공/oversize만
  exact-once commit이며 AppSession `Term`의 Window-local cursor 필드는 0이다. notification은 기존 stable runtime 소비형
  RPC를 유지한다. focused gate는 cursor 2개, RemoteRuntime 1개, 실제 AppSession BEL/read/reconnect routing 3개와
  boundary 1개를 Debug·ReleaseFast로 실행한다. CR2d4는 local queue transfer를 유지하면서 remote Term을 옛 Window
  transfer에서 제외하고, 실제 workspace move/source close와 full-window merge 뒤 같은 stable input record 및 BEL/OSC52
  cursor를 소비하는 AppSession 2개(root/import sentinel 3개 포함 actual 5)+boundary 1개를 Debug·ReleaseFast로
  exact-count한다. CR2e-a는 pointer-free reducer의 job/runtime/local/mutation/close closed state와 job-generation-bound terminal
  summary를 reducer 5개+boundary 1개로 Debug·ReleaseFast에서 고정한다. closed enum inventory와 authority-prefix
  independent legal-event table에서 clean failure만 즉시 old writable로
  복귀하고 ambiguous failure는 old-usability evidence 또는 frozen retry reservation을 요구하며, controller evidence 없는
  publish와 close-pending 뒤 reconnect mutation은 illegal이다. 제품 caller는 0이다. CR2e-b는 final-address mutation
  owner의 active ordinal lease 64개 상한·drain과 copied replay 거부, kind별 paused metadata, 1 MiB/runtime 1개/app-global 8 MiB
  `PausedPaste`, `Clock.boot` 10분 TTL, resend peak reservation과 owned-buffer secure wipe를 substrate 4개+boundary 1개로
  Debug·ReleaseFast에서 고정한다. 제품 caller와 actual stable queue splice는 0이다. CR2e-c는 generic final-address
  `GenerationSlot`의 inline 최초 node와 heap candidate가 같은 payload를 보존하고 current→retiring→tombstone/reclaimed,
  retiring 1개 backoff, inline/heap final-address payload 초기화, OOM/empty·owned abort current 보존,
  copied/stale/cross-slot authority 거부를 4개+boundary 1개로
  Debug·ReleaseFast에서 고정한다. CR2e-d는 실제 `RemoteGeneration` 제품 `PreparedReconnect`를 node final address에서
  prepare하고 stable screen writer gate 안에서 slot current+target을 동시 게시하며, abort/current 보존, allocator fail-index,
  old destructor exact 1을 4개+boundary 1개로 고정한다. CR2e-e1은 `RemoteRuntime` 내부 generation 접근을 단일 current accessor로
  모으고 backend raw field 접근과 attachment 기반 runtime 역산을 0으로 만드는 runtime 2개+boundary 1개 gate다. e2a는 실제
  slot-backed initial/current 저장소와 inline payload↔stable screen publication·teardown을 runtime 2개+boundary 1개로 고정한다.
  e2b는 final-address executor가 reducer state와 inline candidate를 함께 소유하고 actual prepare/abort/publish/reclaim 성공 뒤에만
  state를 게시하는 runtime 4개+boundary 1개 gate다. 31개 Decision의 closed generation-effect table과 initial state에서 도달 가능한
  canonical sequence 전수가 같은 inventory를 소비한다. inline 증가는 runtime당 256바이트, 4,096-runtime 상한에서 1 MiB이고
  runtime size golden이 이를 고정한다. generation mutation이 없는 decision은 이 gate에서 `retain`으로만 분류하며,
  mutation seal·authority/retry/close effect의 실제 제품 결속과 외부 ingress는 e3가 소유한다. e3a1은 actual
  empty-screen candidate→publish→retiring→reclaim allocator ledger의 structural base allocation 1개,
  CR6d typed event-payload allocator와 CR5b-2a retirement preparation owner, `--stream` 화면 byte sink 반영 뒤 Debug 3,536바이트/ReleaseFast 3,520바이트, abort baseline 복원, 두 reconnect 뒤 heap current 1개와 teardown
  final-zero를 runtime 2개+boundary 1개로 고정한다. 가변 screen/metadata를 포함하지 않는 lower bound이므로
  e3a2의 actual bounded-workload ReleaseFast child raw RSS evidence와 기존 host base SSOT를 결합한다. generation
  1개의 최대 구조적 charge는 `base_update_max_bytes`(16 MiB screen+256 KiB metadata), fixed inventory는 mutation
  lease와 같은 64개다. 둘의 곱 `max_tracked_bytes`는 표현 가능한 구조적 bound이고 app-global 정책 예산은
  e3b의 실제 동시 runtime 모델 전에는 확정하지 않는다. final-address fixed entry가 candidate/current/retiring/retry
  역할을 소유하며 exact bound/bound+1·swap/reclaim/abort·rollback/final-zero를
  닫는다. budget 5개+validator 2개는 Debug·ReleaseFast, 실제 64→128 generation workload 1개와 exec child artifact 1개,
  parent/watchdog artifact 2개는 ReleaseFast, boundary 1개는 Debug·ReleaseFast로 실행한다. parent 전용 runner가 canonical
  child artifact 경로를 주입하므로 ambient environment로 parent 역할을 건너뛸 수 없다. exec child는 parent-minted 128-bit run nonce,
  `LOCAL_PEERPID`, stream type을 검증하고 stdio/FD 198 외 inherited descriptor를 모두 닫는다. typed artifact validator는 baseline/pressure
  원시 표본 각 7개의 identity·중앙값, logical/RSS/footprint delta와 64 MiB conservative harness tolerance, child exit 0,
  실제 cleanup receipt의 generation/bytes/allocation zero를 producer와 독립 재계산한다. e3b1은 process-global queued
  admission 64, active resident entry 8, GUI reconnect 전용 128 MiB byte 정책을 독립 SSOT로 고정한다. 작은 charge는
  active 8개까지만 허용하고 `base_update_max_bytes` charge는 exact 7개까지만 admit한다. 각 cap의 다음 budget reserve는
  mutation 0의 typed 거부다. Budget·entry·lease의 final address/PID/process nonce/owner incarnation/domain 결속은 copied,
  fork splice와 same-address ABA를 mutation 0으로 거부한다. admission queue 보존과 후속 drain 재시도는 e3b2가 실제 owner 결속으로 검증한다. daemon의 같은 128 MiB 값은
  별도 process budget과 공유하지 않는다. e3b2는 budget lease와 mutation seal·authority/retry/close effect를 actual stable
  owner에 결속한다. e3c는 sole external ingress와 close
  경쟁·mixed outcome을 열고 모든 logical charge 0과 RSS artifact를 최종 검증한다. e3의 close 경쟁·mixed outcome·app-global
  count/byte budget·peak RSS까지 green이기 전에는 CR2e 완료가 아니다.
  e3b2 gate는 AppSession frame의 sole drain이 process-global admission queue와 resident budget, actual
  `RemoteTermBackend` runtime row를 조합함을 검증한다. max charge 7개가 resident한 동안 다음 sealed row는
  `retry_later`로 동일 projection을 보존하고, 한 lease를 release한 다음 drain에서 actual stable executor로 이전된다.
  executor의 candidate lease는 reducer retain 구간 뒤 generation publish에서 current로 전환되고 terminal reclaim 뒤 0이 된다.
  Debug·ReleaseFast drain 1개+executor 1개+boundary 1개를 exact-count한다.
  e3c1은 reconnect-only `SessionHostCoordinator`의 final address·PID·process nonce·owner thread와 one-turn backend
  singleton projection을 결속하고, AppSession의 기존 direct drain caller를 0으로 내린다. queue/budget/backend owner를
  이동하지 않은 sole coordinator drain과 copied/stale/reinstalled-backend mutation 0을 product-type gate로 검증한다.
  e3c2/e3c3의 typed external event·close/mixed outcome과 CR4 actual socket receipt는 이 gate의 증거가 아니다.
  e3c2는 pointer-free direct-release evidence를 current runtime projection과 exact 비교한 뒤 coordinator가 준비한 final-address receipt를
  process identity, backend singleton generation, runtime handle/row
  generation, live current connection generation, incident/job/shell/attempt/runtime identity에 keyed seal로 결속하고 exact
  `retry_wait_release`에서만 one-shot 소비한다.
  apply 직전 monotonic clock이 sealed deadline 미만인지 다시 확인한다. copied/self-address rewrite/replay/stale row/expired receipt는
  reducer mutation 0이며, 실제 host wire가 이 receipt를 발급했다는 증거는 CR4에 남긴다.
  e3c3은 pointer-free close event와 final-address receipt를 coordinator process identity, backend singleton generation,
  exact runtime handle/row generation/host runtime ID 및 canonical before/event/decision/after digest에 결속한다. coordinator는 caller가 제출한
  reducer projection을 받지 않고 live runtime에서 직접 계산한다. termination request의 bounded future deadline과 apply-time
  expiry, coordinator-clock timeout의 sealed deadline 도달, abandon을 재검증하고 preserve-old, paused notice, publish-new,
  retry freeze, terminal finish 다섯 effect를 actual executor로 실행한다. invalid raw tag, noncanonical payload, copied/self-address
  rewrite, digest 변조, replay, backend row ABA, premature timeout, expired request는 runtime·resident budget mutation 0이며 각 성공
  뒤 candidate/current lease와 retiring graph가 해당 decision과 exact 일치한다. 실제 socket이 close event를 발급하는 제품
  ingress는 CR4 범위이고 이 gate만으로 wire reconnect/termination E2E를 주장하지 않는다.
- CR3a-1(구현): `ConnectionLease` product callback 0인 transport-neutral lease와 generation 1 전용 slot skeleton. 실제
  `HostAdapter`/`Client`를 import해
  final-address `initInPlace`, heap-pinned node 주소 불변, same-address reincarnation, immutable cleanup lease와 one-shot permit의
  move/copy/replay/cross-slot/cross-host/cross-incarnation/stale-generation 거부, raw Client·RPC API export 0, allocator fail-index
  exact-one cleanup을 검증한다. `initInPlace(out,node_allocator,source)` 실패는 source preserved/out pristine이고 성공은 source
  moved tombstone/node exact owner다. single tagged identity issuer의 nested init·failure burn·max-1/max/next reject는 no-wrap,
  source/out mutation 0을 증명한다. node cleanup pin max/overflow, live-pin adapter deinit fail-stop, copied/double release count 불변,
  last release 뒤 Client/node exact-one destroy를 검증한다. fork child PID-domain mismatch에서 low-level mint/consume/tryDeinit의
  typed reject와 callback/free/owner mutation 0, strict 제품 wrapper의 fail-stop을 구분해 검증한다. HostPool membership
  lease와 ConnectionLease는 별개이며 external-pump owner graph는 변경하지 않는다. 증거 수준은 production-type unit이다.
- CR3a-2(구현 완료; 아래는 단계별 검증 이력): 2c2a는 snapshot 전용 permit을 kind-tagged common
  `StreamOperationPermit`/단일 active tuple/process registry로 migration하고 `GenerationBatchRegistry.streamIdle`이
  reserved/ingress/live/releasing 전 상태를 purge blocker로 분류한다. 2c2b1은 대상 stream의 첫 event에 대한 무할당·무변경
  ended hot peek와 비권위적 index hint까지만 구현한다. 2c2b2는 exact binding과 common permit 아래 fixed inline scratch로 전체 Client
  owner graph와 demux queue의 descriptor·allocator provenance·counter·event admission seal·payload·alias를 재검증하고 target map,
  queue별 aggregate seal, checked quarantine capacity를 final-address private preparation에 봉인한다. 이 prepare는 allocation/free/queue 및
  process-global quarantine mutation 0이다. target detach/stable compaction, callback cleanup, post-validation, 실제 quarantine
  reservation/commit과 poison suffix, transport/GUI 제품 배선은 2c2b3 이후다.
  2c2b3a는 Client/allocator/callback/quarantine을 import하지 않는 neutral pure plan으로 target bitset의 stable
  source/target/survivor ordinal과 b2-provided count/byte scalar의 checked survivor 산술만 검증한다. pointer-free/copyable plan/step에는
  address·allocator·payload pointer·scratch reference가 없고 ephemeral cursor만 target bitset을 borrow한다. product queue/scratch/process mutation,
  owner freeze, allocation/free, reservation과 permit/receipt consume은 0이며 b3a만으로 target cleanup이나 2c2 완료를 주장하지 않는다.
  component gate는 empty/none/all, first/middle/last/alternating, source cap/cap+1, target count mismatch, count/byte underflow·overflow,
  forged cursor fail-close, deterministic error precedence/replay와 stable survivor 순서를 Debug/ReleaseFast에서 검증하고 Client·client_slot·allocator·quarantine import와 제품 callsite
  0을 source oracle로 고정한다.
  2c2b3b는 B3b-F(fence)→B3b-S(Client substrate, product caller 0)→B3b-O(ClientSlot orchestration, exact-one caller) 내부 gate로 나눈다.
  B3b-F는 heap-pinned ClientNode의 final-address `ClientOperationFence`와 Client의 nullable non-owning binding을 추가한다. packed atomic의
  shared inflight count와 exclusive/intrusion/terminal bit가 public Client mutation과 commit callback의 entry-check TOCTOU를 막고,
  fork child는 PID mismatch를 atomic 접근 전에 거부한다. deterministic handoff로 shared-first→exclusive Busy/callback 0,
  exclusive-first→cross-thread public mutation AdminBusy/no-op와 intrusion, nested count, stale/copy/rebind,
  same-address node generation ABA, counter overflow/reserved-bit fail-close, parent locked-state fork child의 parent state 불변을
  Debug/ReleaseFast에서 검증한다. atomic load 자체의 호출 횟수는 계측하지 않고 PID-first source order와 parent state 불변을 함께
  증거로 사용한다. 의미 권위는 기존
  `StreamOperationPermit`이며 fence는 kind/binding/receipt/quarantine를 저장하지 않는다.
  ClientSlot의 새 blocker publication은 process registry mutex를 유지한 채 node shared fence를 먼저 잡는다. attachment binding
  reserve와 stream-operation permit publication, generation batch release의 prepare→allocator callback→accounting consume→registry settle
  전체가 이 aggregate shared gate 안에 있어 teardown의 registry preflight와 Client exclusive 사이에 새 blocker가 끼어들 수 없다.
  ClientSlot teardown은 `registry mutex → exclusive fence`를 먼저 획득하고 그 전에는 mutable node graph를 읽지 않는다. preflight
  early return은 callback/mutation 전 abort로 exclusive와 direct-Client intrusion을 함께 0으로 되돌리고, Client commit은 같은 exclusive의
  terminal commit, 그 뒤 registry/node teardown은 typed return 0인
  no-fail suffix여야 한다. callback 재진입과 socket shared-operation 경쟁에서 node를 보존하고, shared operation이 멈춘 동안 teardown이
  graph를 관측하지 않은 채 Busy를 반환하는 것을 검증한다. 일반 permit admission은 node를 역참조하지 않는 allocator TLS precheck를
  fence보다 먼저 수행하여 예상된 callback 재진입이 AdminBusy이면서 exclusive intrusion 0임을 검증한다.
  B3b-F source oracle은 `tryDeinit|ensureUsable|poison|dropBufferedStream|takeEventForStream|releaseEvent|readGenerationBatch`와
  blocking RPC prepare/abort/preflight/execute의 fence-before-TLS/graph funnel, 세 ClientSlot aggregate scope의 begin→defer end→mutation
  순서, Client terminal 뒤 typed return 0을 고정한다. 모든 Client receiver public method의 G/C/U/R closed manifest는 B3b-S의 첫 hostile
  callback test보다 먼저 RED→GREEN으로 닫으며, B3b-F declaration baseline만으로 이를 완료했다고 주장하지 않는다.
  이 manifest는 AST가 첫 parameter 이름과 무관하게 `*Client|*const Client`인 public receiver 91개를 선언 순서와 무관한
  exact set으로 추출해 이름·mutability·G/C/U/R class를 비교한다(`G=40,C=35,U=15,R=1`). G는 guarded post-publication,
  C는 first-graph-read 전 bound-reject와 무관하게 35개 전부의 reviewed prepublication construction/transfer/teardown owner reference를
  `{method,path,canonical_container_path,enclosing_fn,count}` exact multiset으로 제한한다. generation init 4, external transfer 4,
  adoption/materialization 22,
  external-mode teardown 5의 합이 C35와 exact equality여야 한다. tokenizer/AST는 top-level test body만 제외하고 모든 `.method` reference를
  모으며 direct-call이 아닌 function-value alias, sibling/nested/동일 leaf·다른 outer container, 다른 타입의 동명 method를 음성 fixture로
  거부한다. session-host reflection은 codec 등 기존 canonical owner별 normalized token expression/count만 허용하고, 나머지 `src`의
  reflection 보유 7개 파일은 root lexical depth에서 한 번 만든 OS-independent token mask로 top-level test를 제외한 전체 normalized token
  stream digest와 `@field` count를 exact 고정한다. 따라서 semantic
  relocation/variable rebinding, 허용 owner 내부 치환과 외부 `anytype` trampoline을 포함한 Client
  alias·`@TypeOf`·computed name 우회도 fail-close한다. category metadata도 4/4/22/5 exact set이다. generation init은 final-address
  `canMove→move→bind fence→bind ledger→publication`, transfer는 양 Client unbound, teardown은 external-pump owner와 guarded exclusive
  내부 edge를 각각 증명하고 tokenizer/AST token oracle이 transfer prepare→proof→commit→paired move와 commit 내부 source tombstone 순서를
  exact-one으로 고정하고 두 ownership 구간 사이 call set/count를 closed allowlist로 제한한다. register/publish는 argument 무관 callee
  exact-one과 canonical reservation argument를 함께 검사한다. 충돌 없는 `clientProjectionAuthorityDigest` 이름으로 다른 타입의 동명 호출 위장을 막는다.
  register/publish는 exact one이라 early publication을 허용하지 않는다. 인접 G row `enterExternalMode`도
  bound generation Client의 acquire/defer 직후 Busy와 standalone tail adjacency, standalone caller closure를 중첩한다.
  U는 ClientSlot authority caller exact 제한, R은 mutable Client graph를
  읽지 않는 atomic-only observation이다. `clientProjectionAuthorityDigest|externalTransferProfile`과 external-adoption graph reader는 C,
  non-atomic `terminalReasonInvariant|firstPoisonReason`은 G이며 R은 `endedPurgeFenceIntruded` 하나다. 모든 body에 공통 substring을
  반복하지 않고 direct gate/funnel kind와 위험한 U/C caller만 별도 source oracle로 검사한다. 91-row set equality는 inventory
  subgate일 뿐이며 이 class별 policy oracle이 모두 GREEN이 되기 전에는 closed manifest나 hostile callback 선행 gate 완료로 세지 않는다.
  policy closure는 G→C→U→R로 닫는다. G40과 allocator-domain U2의 합집합은 acquire/release prefix·brace depth·pre-gate field
  allowlist까지 가진 42-row exact proof set으로
  top-level receiver→funnel 유일 위임, shared held capability와 바로 다음 defer-release의 결속, exclusive deinit 특례와 private trusted
  guard chain을 AST/token source-order로 검증한다. 이 gate만 GREEN인 상태에서는 C/U/R 또는 전체 closed manifest 완료로 세지 않는다.
  allocator-domain U 두 row는 authority proof와 별개로 같은 shared guard proof를 동시에 통과해야 한다. shared `catch`형은 gate call 뒤
  optional error capture와 `return`만 허용하고 반환식의 `self` 접근을 0으로 고정하여 fail-open continuation을 거부한다. trusted transfer는
  동일 held capability 외 성공 반환을 금지하고, exclusive deinit은 exact acquire identity·catch-return·latch-bound deferred abort·terminal
  commit 뒤 disarm을 검증한다.
  B3b-S는 blocking generation-only complete Client-owned deinit graph 64 MiB checked cap, `build_id`·`Client.lifecycle`·`pending_outbound`
  owner SSOT와 각 exact-owned frozen descriptor, private immutable/no-escape scratch,
  별도 advance-before-callback cleanup cursor, stable compaction/counter publication, all-target exact-once callback, scalar-first post-validation과
  absorbing `quarantined_no_free` poison을 caller 0인 Client-local transaction으로 완성한다. drift commit은 graph tombstone 뒤 sealed
  preparation을 `finalization_pending`으로 남기고 poison/terminal/quarantine mutation은 0이다. 실제 ClientSlot permit/receipt/quarantine 배선은
  B3b-O만 소유하며 clean은 reservation release 뒤 node permit→transport receipt를 paired consume하고 Client exclusive clean release를
  마지막으로 수행한다. drift는 quarantine commit이 발급한 exact-once
  `CommitReceipt`를 trusted `Registry.consumeCommitted`가 consume해 pointer-free `ConsumedCommitProof`를 발급한 뒤 finalizer가
  proof를 검증하고 poison fields/`PreparedEndedPurgeCommit` consumed를 게시하며 terminal fence를 마지막으로 publish한다.
  finalizer identity/lifecycle/proof mismatch와 validated quarantine commit 실패는 `@panic` process fail-stop이다.
  private scratch의 coherent arbitrary overwrite와 cleanup authority 밖에서
  이미 수행된 deallocation의 탐지·복구만 비목표이며 public reentry·canonical drift·allocator provenance/alias gate는 유지한다.
  b3b executable gate는 callback 전후 scratch byte 동일/no-escape, first/middle/last callback 진입 때 cursor가 이미 다음 ordinal인 관측,
  outer/scalar/survivor drift, outer/scalar
  mismatch의 payload read/hash 0, scalar exact/content drift의 payload hash exact 1, 모든 원 target callback exact 1, stable survivor order,
  public reentry `busy`, normal/drift prevalidated node permit→preparation transport receipt paired consume, clean exclusive-last와 exact drift suffix 순서,
  one-slot sticky/64 MiB/replay charge 0,
  모든 postcallback drift의 fd close 0, callback close→same-number `dup2` fd identity ABA의 fstat drift, `.not_ended` 대형 scratch 0을 고정한다.
  generation Client fd의 precondition은 `S_IFSOCK`+`SO_TYPE=SOCK_STREAM`이며 CI fixture의 close→new socket, regular file, EBADF
  same-number 교체는 drift, replacement fd close/write 0이다. tuple 재사용이 불가능하다는 일반 socket/OFD identity 보장은 주장하지 않고,
  coherent raw fd 교체는 지원 밖 fail-stop 위협이다.
  B3b-S는 valid `finalization_pending`만으로 finalizer를 호출하거나 copied/moved/same-address-reset preparation, old/cross
  operation generation, missing/copied/old/cross-registry `CommitReceipt` 또는 mismatched/cross-operation proof를 주입하면 Client/fence/preparation mutation 0 뒤 subprocess
  `@panic` abnormal nonzero exit임을 Debug/ReleaseFast 2초 watchdog으로 고정한다. receipt consume 뒤에는 ownership/first reason,
  `PreparedEndedPurgeCommit` consumed, terminal-last publication 순서이며 terminal 관측자는 앞 필드를 모두 final로 본다. B3b-O는 reservation mirror drift로
  `Registry.commit`이 false인 경우 finalizer/poison/terminal/node permit/transport receipt consume 0 뒤 같은 fail-stop을 검증한다.
  node permit과 preparation transport receipt는 callback 전 함께 prevalidate하고 suffix에 allocation/lock/fallible lookup 0으로 permit부터
  consume한다. 둘 중 하나의 stale/copy/splice는 precommit 양쪽 보존이고 committing 뒤 mismatch는 process death이며 반쪽 정상 반환은 0이다.
  clean suffix의 reservation release 뒤, node permit consume 뒤, transport receipt consume 뒤 barrier마다 concurrent public Client call은
  exclusive clean release 전까지 `busy`이고 Client/queue/fd mutation 0이며, exclusive clean release 뒤에만 새 public mutation이 성공한다.
  terminal publish 뒤 paired consume mismatch fixture는 다른 thread가 node destroy/reuse를 관측하기 전에 watchdog이 즉시 abnormal exit를
  회수하고, 정상 반환·추가 callback·다음 admission marker가 0임을 고정한다.
  `Registry.commit` receipt out과 Registry/Reservation, `consumeCommitted` proof out과 Registry/receipt의 exact·partial alias는 false와
  모든 입력 byte 보존이며, ClientSlot은 두 out과 Client/fence/prepared/preparation/scratch/inventory alias를 precommit typed error로 닫는다.
  Client는 quarantine Registry/Reservation/pointer receipt나 임의 callback을 받지 않고 pointer-free consumed proof만 검증한다.
  B3b-S에서 Client prepare/commit/finalize의 test 밖 production caller는
  0이고, B3b-O에서 ClientSlot method 하나만 각각 exact once 호출한다. direct cleanup leaf가
  reentry-guarded public release API를 호출하지 않고, neutral module은 pure helper만, `client.zig`는 DTO adapter/queue mutation/direct cleanup만,
  `client_slot.zig`는 permit/receipt/quarantine orchestration만 소유하는지 source boundary로 검사한다.
  doc-first source gate는 AST canonical `(parent,kind,visibility,modifier,name)` inventory로 root와 owner container를 검사하고,
  허용 tuple 제외 baseline client(root+Client+EndedPurgeScratch+PreparedEndedPurgeInventory)=527/SHA-256
  `594178e6c653e30be0ddc64564d2783922e0c0b4895c3543479f86e5977db6fd`,
  client_slot(root+ClientSlot+EndedPurgePreparation)=126/SHA-256 `03a92a146dbf8935466d0b9250b09c884d575f15fc148f73c6db8979bc69d968`를
  함께 고정한다. client top-level delta는 `ClientOperationFence|generationAllocatorCallbackActive|ended_purge_transaction|ended_purge_quarantine|
  PreparedEndedPurgeCommit|EndedPurgeCommitError|
  EndedPurgeClientCommitOutcome`, client_slot delta는 `ended_purge_quarantine|ended_purge_quarantine_registry|process_runtime_pid`만 허용한다. nested
  Client/ClientSlot/EndedPurgePreparation method/type도 persistent-session-host의 exact allowlist 밖 증가는 실패한다. 새
  `ended_purge_quarantine.zig`는 std 외 import·allocator·Client·callback·payload pointer 0, public API
  `max_ended_purge_quarantine_bytes|Error|Reservation|CommitReceipt|ConsumedCommitProof|Registry` exact 여섯 개와
  nested `Reservation.Lifecycle`, `CommitReceipt.Lifecycle`, `ConsumedCommitProof.matches`,
  `Registry.State|init|reserve|release|commit|consumeCommitted` 및 persistent-session-host의 exact field schema를 함께 고정한다.
  proof는 runtime authentication capability가 아니므로 semantic-exact scalar copy를 거부한다고 주장하지 않고, B3b-O exact caller와
  `Registry.consumeCommitted→finalizer` source order가 제품 authenticity를 소유한다.
  **B3b-O는 구현 완료다.** `EndedPurgePreparation`의 final-address
  `prepared→committing→consumed` 전이와 abort/재시도 차단, Client prepare/commit/finalize production callsite exact one,
  clean의 reservation release→node permit→transport receipt→exclusive release, drift의 Registry commit→consume→finalizer→node permit→transport receipt를
  product-type test와 source-order oracle로 먼저 실패시킨다. Debug·ReleaseFast subprocess에서 validated suffix mismatch가 정상 반환이나 다음 admission 없이
  fail-stop하는 증거를 Debug·ReleaseFast 및 boundary에서 green으로 고정한다.
  permit registry는 mutex-protected register와 per-entry atomic `empty|live|consume_reserved|consumed` terminal consume을 분리한다. callback 전
  final-address consume receipt 준비 뒤 callback 후 `consume_reserved→consumed` CAS, node tuple clear, preparation consume,
  `consumed→empty` reclaim만 허용하며 entry payload clear는 0이다. `consumed` 동안 같은 index 등록은 실패해야 한다.
  canonical operation-thread 선검증과 same-thread exact-one consume, copied/moved/replayed receipt, 같은 index old-id ABA,
  CAS→tuple clear→receipt consume의 무개입 source order와 foreign-thread teardown 선거부, sibling entry progress,
  initial snapshot abort/consume 무회귀와 raw state 전수 검증을 Debug·ReleaseFast에 고정한다.
  `ClientSlot.initializeProcessRuntime`을 AppSession의 fork 가능 작업 전에 명시적으로 호출하고 pre-fork parent PID `init` exact-one과
  같은 PID idempotence, non-test `process_runtime_bootstrap_fixture.zig`의 미초기화 ClientSlot 생성 거부와 bootstrap 뒤 실제
  ClientSlot 생성·valid·deinit 및 macOS fork child의 mutex-before-reject 0,
  self-exec 뒤에만 thread runtime을 시작하는 non-test `ended_purge_quarantine_concurrency_fixture.zig`의 2초 watchdog·8-thread
  single winner·exact release, `idle|reserved|committed`/reserve-release-commit/replay/cap/cap+1을 Debug/ReleaseFast로 검증한다.
  `pending_outbound` non-null도 `build_id`·`Client.lifecycle`과 함께 각각 독립된 frozen scratch descriptor,
  complete-owner sum/alias/seal/postvalidation/tombstone에 포함하며 b2의 기존 adoption-only null 가정을 purge authority로 재사용하지 않는다.
  `client_lifecycle: ExternalArrayDescriptor`는 zero default이고 exact-owned slice를 `capacity=len`으로 canonicalize한다. empty는 address/len/capacity
  모두 0이며, current descriptor와 모든 owner range의 exact·partial alias를 payload/hash 전에 검사한다. callback 뒤에도 frozen scalar와
  정확히 일치할 때만 Client lifecycle contents를 hash한다.
  AST gate는 `PreparedEndedPurgeCommit`이 나타나면 exact `Lifecycle=enum(u8){pristine,prepared,finalization_pending,consumed}`+19 fields
  (`finalization_seal` 포함)를 검사하고, drift finalizer가 pointer-free preparation transcript를 재계산해 seal mismatch를
  poison/terminal mutation 0의 fail-stop으로 닫는지 검사한다. Debug/ReleaseFast fixture는 inherited parent PID proof의 process-domain
  mismatch, lifecycle raw byte 0~255 중 `finalization_pending` 외 전 값의 raw-state mismatch, preparation transcript 각 field와 네 plan의
  state/6 scalars 및 fence identity 각각의 seal 민감도, batch/stream/event/partial 혼합 owning commit의 stable survivor·counter·cleanup ordinal을
  검증하고,
  `ClientOwnership.quarantined_no_free`와
  `EndedPurgePreparationLifecycle{empty,prepared,committing,consumed,aborted}` 외 enum 증분을 거부한다. 각 신규 import는 raw substring이
  아니라 AST initializer가 exact `@import`인지 검사한다. fork-child RED는 모든 process-global lock 전 PID 거부를 고정한다.
  generation 1 compatibility wiring으로 GUI raw `RemoteRuntime.client=*Client`와
  `AttachmentTransport.context=*Client` production callsite 0, GUI-only final-address `GenerationAttachment.initInPlace`,
  external movable `RemoteAttachment`의 outer field 목록·기존 `untracked|charged` reachable 의미와 external `Prepared|Attached`의
  outer owner schema 불변(`AttachmentBatchLease` 내부 generation variant/layout 변화는 허용), live transport와 cleanup lease 분리,
  batch table 0/1/4096/4097과 별도 stream-drop table 0/1/4096/4097의
  one-shot permit, 실제 attach/pump/deinit·failed-release·callback reentry에서 bound generation-1 node cleanup exact 1,
  slot/current admission과 별도 sentinel node mutation·wire 0을 검증한다. lease 발급 뒤 attachment move/copy와 기존
  GUI generation-bound attachment return-by-value production construction은 0이다. neutral pre-attach binding은 self/incarnation/
  lifecycle seal 아래 node pin과 빈 registry entry를 먼저 예약하고 그 뒤 Client가 같은 owner turn에서 만든 typed attach request
  receipt를 no-fail pair한다. binding/request 어느 준비 실패도 wire 0과 request/TX/pin/drop final-zero이며 copy/move/two-address/
  same-address ABA abort·commit은 mutation 0이다. execute 전 abort와 execute 뒤 typed reject만 connection을 유지하고, execute 시작
  전에는 `ExecutedResponse` pristine/final-address/incarnation/non-alias/allocator를 wire 0으로 preflight하고 copy/move/same-address
  ABA/alias/fail-index 실패가 request/binding/out mutation 0임을 검증한다. execute 뒤에는 outcome과 무관하게 request slot/TX
  backing owner가 내부 exact settle된다. response allocation OOM은 payload owner 0+close이고, accepted만 caller final-address
  `ExecutedResponse`에 request backing과 별개인 bounded owned response bytes+digest+allocator와 pointer-free receipt를 seal하고,
  typed reject/uncertain은 payload owner 0이다. response copy/replay는 payload read 전 거부하며 success/malformed/binding mismatch
  모두 exact once free한다. uncertain/connection failure나 accepted decode 실패는 response deinit+local binding abort+connection
  close다. valid stream ID
  commit은 prepared pin을 pristine lease로 allocation/failure/pin-count 변화 0으로 이전한다.
  valid-shaped accepted의 request-ID cross, duplicate replay, stream reuse/splice, binding mirror/destination mismatch도 canonical
  attachment mutation 0 뒤 offending connection close와 server subscription final-zero다.
  execute 전 abort, typed reject, accepted valid, accepted malformed, accepted binding mismatch, uncertain 각각의
  `{prepared request owner,TX backing,response payload,binding,pin/drop entry}` final-zero/consumed/terminal 상태를 전수한다.
  request/execute allocator scope는 final-address token copy/move, exact/partial allocation alias, purpose/client/epoch/allocator splice,
  duplicate restore, padding 비의존 pristine 판정과 epoch 소진 mutation 0을 검증한다. response tombstone은 live owner seal 없이는 generic
  deinit이 승인하지 않고, registry clear 뒤의 finish/attachment teardown 재호출도 성공으로 접지 않고 fail-close한다.
  declared owner range의 transport/storage 미포함 및 slot/node/Client/owner-seal partial overlap과 executing request의
  allocator-scope·response-incarnation issuer exact-max/cap+1을 닫는다. publication 전 transport/registry issuer 소진은 별도
  mutation-zero gate로 유지한다.
  같은 token의 two-address prepare, prepare→reentry→consume/abort, nested permit,
  permit callback 안 parent release/deinit은 typed busy이고 active permit 0 뒤에만 pin release가 성공한다. node-local GUI cleanup
  registry에서 duplicate release/drop과 node 조기 destroy는 0이다. buffered Client queue 또는 direct parser descriptor에서 같은
  Client transferred accounting+registry descriptor→pointer-free attachment token publish는 all-or-none이며 18 MiB/4096-item 합계를 이중 계수하지
  않는다. allocator callback 반환 전까지 transferred charge를 보존해 cross-stream reentry도 resident cap을 넘지 않는다.
  reserve-first read의 `idle|terminal|error`는 entry를 exact abort하며 0/1/4096회 idle 뒤 live count 0과 다음 batch 성공을 검증한다.
  stream drop callback 동안 node-wide batch admission은 닫혀 기존 pending accounting의 decrement-before-free 순서에서도 다른
  stream resident cap 초과가 0이다. ordinary release와 exact residual terminal receipt의 node drain은 captured allocator payload를
  합쳐 exact once free하고, allocation
  authority가 불명확한 indeterminate entry는 bounded no-free quarantine이라 재해제하지 않는다. CR3a-2 제품 cancel callback은
  0이고 CR3b R1이 별도
  소유한다. permit preflight stale/move/splice/fail-index는
  private owner receipt로 reservation available·active cleanup 0을 exact once 복구하고 callback 0이다. callback
  `completed|retryable_preserved|indeterminate_or_partial` 각각 consumed|available|terminal 전이, 1회 retry 실패 뒤 deinit 재시도,
  `tryDeinit()` busy와 strict `deinit()` fail-stop을 production type으로 검증한다. private receipt 자체 손상은 callback/free와
  canonical reservation/resource-owner mutation 0, owner address+reservation ID quarantine latch/accounting exact once와 후속 component
  operation typed reject를 검증한다. process fail-stop은 실제 owner-specific strict adapter가 생기는 CR3a-2 gate다.
  first retryable 뒤 deinit의 second
  completed/retryable/indeterminate 세 경우는 각각 cleaned/terminal_handoff/terminal_handoff, attachment local owner 0, poison과
  node/ledger terminal owner exact 1을 검증한다. 첫 indeterminate/두 번째 retryable 뒤 남은 token 전부의 aggregate terminal
  handoff, registry drain/quarantine→Client.deinit→node destroy 순서를 검증한다. batch release completed/retryable은 stream open,
  stream drop completed는 terminal, indeterminate/second retryable만 terminal_handoff인 entry/stream 직교 표를 전수한다.
  2c는 2c1(구현) initial snapshot final-address owner, 2c2 sealed ended receipt+all-or-none early purge, 2c3 closed
  capability/input/control/event/RPC primitive, 2c4 `RuntimeConnection` union+exact 15-method source oracle 순으로 병합한다.
  2c3은 2c3a input/revoke/output-progress+raw lifecycle admission, 2c3b capability+closed RPC, 2c3c control,
  2c3d one-shot event와 repo-wide event/effect source-zero, 2c3e RPC/decoder direct-call source-zero+immediate EOF/unread RX-first
  socket parity로 나누며 모두 green 전 2c3 완료를 주장하지 않는다. 중간
  gate는 자기 raw allowlist만 줄이며 2c4 전에는 `RemoteRuntime.client` 0이나 2c 전체 완료를 주장하지 않는다.
  2c4 focused gate는 Debug·ReleaseFast에서 `RuntimeConnection` exact two-arm schema, 네 public constructor의 arm 선택,
  공통 private constructor/teardown의 단일 connection 인자, semantic facade 15개 이름·signature, generation raw Client source-zero,
  legacy raw call reviewed allowlist와 기존 attach/input/control/RPC/event/purge/poison/teardown parity를 검증한다. boundary 1개는
  제거 대상 여섯 항목과 nullable-adapter mode switch 0, reconnect/current publish 0을 exact-count한다.
  2c3a는 generation 제품 input/revoke/output-progress의 direct Client 호출을 0으로 만들고 legacy baseline은 유지한다.
  exact public signature와 closed error/outcome은 persistent-session-host SSOT를 따르며, accepted byte ownership, 0-byte
  backpressure, revoke-before-input, zero/partial pending frame, controller/observer, copied/moved/fork/foreign-thread,
  stale slot/node/binding, cleanup busy, OOM/socket failure를 production type과 Darwin socketpair로 검증한다. facade public
  lifecycle은 raw `u8` 0...255 sweep를 Debug/ReleaseFast에서 통과해야 하고 invalid tag는 Client/node/wire mutation 0이다.
  현재 2c3a 자동 증거는 `GenerationTransport`/`GenerationAttachment` lifecycle 전수 sweep, canonical registry/entry/role
  raw-first admission, direct `ClientSlot` authority의 foreign-thread·fork·invalid-role 전수 거부, stale slot/node/binding,
  controller/observer, allocator OOM·닫힌 socket, zero/partial pending frame을 production-type unit과 Darwin socketpair로
  실행한다. `RemoteRuntime` generation attach 제품 경로는 partial frame revoke가
  `outbound_partial_write` poison 뒤 `ConnectionClosed`로 닫히는 것까지 real socket으로 검증한다. bound drop은 controller
  `live -> revoked`와 `bound -> drop_active`를 같은 registered-node operation에서 게시하고 pending revoke·live/pending clear를
  mutation 없이 거부한다. 이 증거는 2c3a만 닫으며 capability/RPC/control/event/source-zero는 2c3b~e, raw field 제거는 2c4다.
  connection-wide buffered revoke는 generation 조회와 `Client` blocking/deadline RPC의 pre-flush gate를 함께 통과해야 하며,
  sibling RPC·detach가 pending mutation wire를 보내지 않는 socketpair 회귀를 포함한다.
  2c3b-1 capability facade, 2c3b-2 request-side authority와 2c3b-3 B3-0a~B3-6 internal aggregate는 구현·검증 완료했다.
  public decoder와 legacy/generation observable parity는 2c3e 후속이다. 2c3b-2는 관측 가능한 wire/product behavior를 유지하면서 request authority와 기존
  attach-compatible response execution의 begin/revalidate/settle hardening까지만 닫는 gate다. 14-tag family/role/phase/method 전수표,
  node-entry `PreparedRequestAuthority` raw lifecycle과
  settledExact, opaque prepared storage와의 all-or-none prepare/abort, canonical frame descriptor·allocator provenance, registry-first
  admission을 Debug/ReleaseFast에서 검증한다. allocation fail-index, copy/move/same-address restore, cross binding/tag splice, forged
  ptr/len allocation extent/allocator와 owner range alias는 frame hash/역참조/free/wire 0이어야 한다. prepared frame은 allocator가
  반환한 exact owned Zig slice이므로 독립 capacity 권위가 없고 allocation extent는 `len`이며, free도 exact slice만 받는다.
  `spawn_full`은 connection-only denied로
  prepare 전 거부한다. public RuntimeRequest의 arbitrary method/encoded JSON/stream ID escape는 0이고 typed variant DTO에서 canonical
  binding stream과 role-sensitive discriminator를 한 번만 encode한다. exact `PrepareError|AbortError`와 Client error mapping을 compile-time
  inventory로 고정하고, GenerationTransport direct prepared Client API callsite는 0이며 기존 attach socket parity는 유지한다.
  제품 타입의 `prepared request rejects a live cross-binding transport splice`와
  `stale prepared receipt fails after same-address transport reincarnation`이 각각 두 live binding 사이 receipt 교차 결합과
  동일 final address 재민트 뒤 stale receipt의 execute/abort 거부를 직접 고정한다. registry가 response owner를 settle한 뒤에는
  `registry-cleared uncertain response rejects finish and attachment retry`와
  `registry-cleared typed reject rejects finish and attachment retry`가 finish/teardown 재호출의 `corrupt` 수렴을 고정한다.
  2c3b-3만 `attach:*ExecutedResponse|rpc:void` destination, 반복 RPC response authority와 response payload borrow/finish behavior를 연다. 구현 gate는
  `capabilities(*const GenerationTransport) -> error{Busy,InvalidOwner}!GenerationCapabilities`의 raw-first admission,
  capability DTO exact-field projection과 closed request tag 전수 mapping, attach 전용 one-shot
  `ExecutedResponse`와 반복 RPC 전용 transport epoch authority의 분리를 검증한다. 반복 RPC는 2회·64회 순차 성공과 pre-wire reject 뒤
  다음 요청을 허용하되, accepted 미소비·uncertain·correlation/allocator/alias drift는 connection terminal로 닫는다. final-address
  `RpcExecutedResponse` borrow/owner-only finish는 copy/move/same-address ABA, cross transport/binding/request/digest/epoch splice,
  duplicate borrow/free와 allocator callback 재진입에서 wire·canonical mutation·double-free 0이어야 한다. attach/RPC destination tag
  mismatch, epoch 0/max 소진, prepared abort와 published response abort 혼동, executing/published/borrowed/releasing teardown을 production-type
  Debug/ReleaseFast와 Darwin socketpair로 검증하기 전 2c3b 완료를 주장하지 않는다. registry attach response seal의 reset/recycle과
  호출 수에 비례하는 response destination 배열/free-list/heap pool, 독립 movable payload와 계속 실행하는 quarantine registry는 이 gate의
  구현이 아니다. RPC는 canonical transport inline slot 하나만 사용하고 성공한 reusable finish의 private same-operation suffix만 이를
  pristine rearm한다. publication 실패는 exact
  safe-free와 ambiguous no-free를 구분하고 후자는 node terminal evidence 뒤 strict product subprocess fail-stop으로 수렴해야 한다.
  **2c3b-1 자동 증거:** compile-time exact signature/error-set, granted+supported와 frozen+unsupported의 교차 true/false 전 필드,
  lifecycle/role/attach-schema/metadata/owner-seal invalid raw-byte 전수, copy/move/fork/foreign-thread, stale slot/node/binding 및 unmapped
  slot 주소, same-address restore, stream-operation residual field와 active-cleanup `Busy`를 검증한다. boundary
  `CR3a-2c3b capability projection and shared RemoteRuntime raw-read baselines cannot expand`는 registry-resolved projection 1회, generation 제품
  `capabilities()` callsite 0과 `remote_runtime` shared architecture raw-read exact baseline이 2c3e 전까지 증가하지 않음을 고정한다. 이 증거는
  `zig build check-boundaries`와 Debug·ReleaseFast `zig build test-session-host`가 모두 green일 때만 유효하다.
  whole-transport+stack response same-address restore도 node-sealed epoch/lifecycle을 되살리지 못해야 한다. pending mutation frame partial
  flush 실패는 새 RPC byte 0이어도 terminal이고, mutation-zero pre-wire reject만 idle 재사용한다. raw response borrow의 production 저장/
  반환·transitive helper callsite 0, exact decoder caller/signature inventory와 reusable/protocol-failure finish의 idle/terminal 분기를
  tokenizer source oracle·compile-time inventory·socketpair로 고정한다. 이 gate의 product source oracle은 private borrow bridge와
  실제 RemoteRuntime callsite 0 baseline까지만 소유하고, family decoder 전환·application error/malformed disposition·legacy/generation
  parity는 2c3e에서 닫는다. 반복 RPC는 accepted/uncertain만 만들고 typed reject는 attach
  호환 arm에 한정한다. request family/phase/role/destination별 exact `ExecuteError|ExecuteResult` 표를 전수한다.
  내부 merge 순서는 `B3-0a ambiguous-free remediation → B3-0 transaction seam → B3-1 inert authority → B3-2 private destination →
  B3-3 progress/execute → B3-4/5 atomic publish+borrow/finish → B3-4/5 single-slot correction+private substrate ownership-only settlement path →
  B3-6 internal aggregate strict completion`이다.
  B3-0은 current attach exit decision table의
  result/error, backing/authority settlement, 최초 poison, response lifecycle/bytes와 allocation/free count를 differential
  characterization하고 public declaration/callsite/frame/registry-layout delta 0을 source oracle로 고정한다. B3-0a는 operation-scoped
  framing의 단일 outstanding payload 상태기계에서 산출한 in-place 1-entry payload allocation ledger와 private observer의 0/1/64/누적 cap 초과, Darwin
  socketpair의 OOB→target accepted 왕복, OOB immediate `live->retired` slot reuse 뒤 Frame generation 기반 target promotion, observer 밖 parser/pending
  backing resize/remap parity, target 전후 OOB free, ledger heap backing allocate/grow/free 0, pre-parent generation max/wrap,
  zero-length, ptr/len scan 0, wrong-generation promote의 read/hash/free 0과
  alias·overflow·allocator drift no-free와 free callback 뒤 ledger descriptor scalar-first 검증을 검증한다. private component의 `fail_stop_required`는 exact production consumer
  `client_slot.executeGenerationRequest` 밖 callsite/return/store 0이고 subprocess abnormal exit여야 한다. B3-0은
  `PreparedExecutionTxn` in-place init, phase×method, copy/move/duplicate와 decision table 각 행의 storage/authority/poison/free를
  Debug·ReleaseFast production type으로 전수한다. B3-1은 final-address `RpcResponseAuthority` leaf와 cleanup-registry의 exact
  `rpc_response_authority` idle field를 production-type unit으로 검증한다. raw lifecycle 전수, checked epoch 0/max, copy/move,
  same-address reservation ABA, cross-binding/transport/request/destination splice와 idle/terminal-settled 대 busy/corrupt teardown을
  payload read/free·wire·제품 execute callsite 0으로 고정한다. full-authority same-address restore는 registry current binding으로
  거부하고 nested binding 전 필드와 epoch 0/max를 전수한다. module-public 전이는 executing reserve/rollback/terminalize만 허용하며
  이후 lifecycle은 leaf test-private다. authority `<=256 B`, registry 4,096-entry 증가량 `<=512 KiB`도 고정한다. stale
  authority+stale identity를 현재 reservation에 함께 splice하는 경우, 같은 주소 registry reincarnation 뒤 reservation ID 1 재사용,
  tag-family 전수·bound RPC-only 구조 불변식도 포함한다.
  role/phase/stream/destination admission은 B3-2의 exhaustive classifier가 소유하고,
  classifier SSOT는 `AttachmentCleanupRegistry` 하나이며 prepare는 decoded request, execute는 exact
  `{reservation,binding,transport,receipt,stream,AdmissionContext}`로 canonical prepared transcript를 다시 resolve한다. context는 raw-first
  `prepare|execute_attach|execute_rpc`인 closed enum 하나이며 stage/destination 이중 입력은 없다. public execute wrapper는 execute attach만
  투영하며 execute rpc 제품 caller와 public destination ABI는 0이다.
  current stream은 final-address `GenerationTransport.requestOperation`이 제품 callsite에서만 투영하는 non-authoritative drift probe이며
  canonical entry보다 권한을 넓히지 못한다. source oracle이 그 exact projection을 고정한다. 반환은
  `Error{InvalidOwner,InvalidReceipt,InvalidResponseDestination}!Decision{allowed,unauthorized,busy}`이고 public structural preflight 뒤
  outer-operation `Busy` → raw context → owner/raw entry →
  receipt/raw request → connection-only → destination → semantic authorization의 exact precedence를 검증한다. detach는
  observer/unavailable과 controller/live·revoked를 허용하고 controller/revoke-pending은 busy다.
  14 tag×5 family×3 context×entry phase `empty|reserved|bound|drop_active`×role×controller state×
  `entry_stream {0,A,B}`×`current_stream {0,A,B}`와
  find 두 family, invalid raw 0..255, identity/receipt/transport/destination splice, same-address registry ABA를 production type으로 전수하고
  reject 전후 registry/prepared/RPC authority/response owner/stream state byte 동일성과 storage access 0을 검증한다. pure classifier의
  spawn/invalid-family deny와 product prepare의 publication 0·execute unreachable receipt 오류를 구분한다. B3-2에는 socketpair·Client·flush·
  allocator·payload·response publication·RPC epoch mint가 없으며 Debug·ReleaseFast exact-count focused gate와 boundary/source oracle이 이를
  고정한다. verdict는 permit이 아니며 B3-3은 pre-flush `.prepared`, begin-execute 뒤 post-flush `.executing` transcript를 같은 receipt로
  각각 새로 resolve해 동일 classifier를 재호출한다.
  B3-3의 완료 증거는 caller-final storage에 Client가 in-place 초기화·seal하는 `PreparedRequestExecutionLease`와 closed
  `PreparedRequestWireProgress{request_zero_clean,prior_pending_ambiguous,request_maybe_written}`가 lifecycle/error/byte-count
  추론 없이 pending flush와 새 request의 positive write에서만 단조 전이하는지 검증한다. exact 제품-shaped 순서는
  `preparedRpcAdmission→initPreparedRpcExecutionTxn+defer→reserveRpcResponseExecution→beginPreparedRequestExecute→beginPreparedRequestExecution→executingRpcAdmission→
  first tracked write`이며 pre/post classifier는 같은 canonical resolver를 exact 1회씩 사용하고 post verdict 저장은 0이다.
  reusable rollback은 prior ambiguity 0을 포함한 `request_zero_clean && Client usable`의 교집합에서만 prepared backing exact free와 RPC
  authority `executing→idle`을 함께 게시한다. prior pending partial, request positive write, closed/poisoned Client와 epoch 소진은 terminal이다.
  Debug·ReleaseFast focused gate는 progress raw/monotonic 전수, 두 authority의 reserve/rollback/terminal, response destination의
  full owner graph/frame alias와 pending-free callback 점유, execution fence의 null/foreign/generation/same-address-incarnation ABA를
  고정한다. callback 뒤 destination 점유는 request write·second free 0, 양 authority terminal, fail-close로 닫는다. receipt/stream/
  role/controller/registry 정책 전수는 B3-2 classifier gate가 소유하고 B3-3 boundary가 pre/post 호출 순서를 고정한다. Darwin
  socketpair는 작은 `SO_SNDBUF`와 peer drain/close로 actual kernel의 pending/request zero·positive partial·full 및
  EOF/EPIPE를 관측하고 peer parser가 prior frame과 새 request prefix/full을 분리한다. exact 1/len-1, EINTR retry, EAGAIN/zero/hard
  error 조합은 injected write ops로 결정적으로 전수한다. boundary는 legacy `writeAll` request call 0, pre/post admission과 RPC
  authority 전이 allowlist, post-classifier 뒤 first-write adjacency, public RPC destination·response publish/borrow 0을 고정한다.
  B3-3에서는 correlated response를 제품 publish하지 않고 peer가 exact request를 읽은 뒤 EOF를 내는 test-private terminal sink만 쓴다.
  pristine `RpcExecutedResponse`의 exact address/range/disjoint를 response reserve 전에 txn이 봉인하고 payload/publication
  API 0을 유지하는지 검증한다. final-address `PreparedRpcExecutionTxn`이 reserve 전에 mutation 0으로 초기화+defer 설치되고 기존 request
  transaction을 재사용하며 response canonical과 `pristine|response_reserved|settled` phase만 합성하는지,
  wrapper가 여는 reserve/lease 뒤 rollback, response epoch 소진의 wire 0·fail-close, pending ambiguity, request hard failure, frame alias, full-write+EOF 및
  callback destination 점유에서 request cleanup이 response rollback/terminal보다 먼저 끝나는지, 별도 request-free 구현과 progress
  bool/cached verdict가 0인지도 source oracle과 callback reentry로 검증한다. source oracle은 request settlement→RPC settlement→execution
  fence release 순서를 별도로 봉인한다. B3-3 private production wrapper fixture는 3개 테스트에서 exact 8회 호출하며 테스트 밖 제품 caller와
  public ABI delta는 0이다. Darwin fixture의 wrapper 검증과 Client lease/raw-write leaf
  검증은 구분하고, wrapper 결과로 prepared/RPC authority의 reusable 또는 terminal 정산, 필요한 connection poison과
  request backing final-zero를 단언한다.
  lease 내부 신규 mutex/atomic/TLS는 0이다. 기존 Client mutation fence에서 독립 진입은 execution state를 exact once 획득·해제하고,
  registry operation이 이미 가진 single shared pin은 `shared(1)→execution→shared(1)` CAS 승격·강등으로 node pin을 잃지 않는다.
  B3-4/5는 published payload의 생성·정리 primitive와 one-shot `[63]` response 배열 제거, canonical inline single-slot correction을 완료했다.
  B3-6 internal aggregate strict completion은 production strict-wrapper subprocess까지 증거 수준을
  높인다. B3-4/5는 기존 response loop의 response-only 추출, 별도 `rpc_executed_response.zig` byte owner, registry-owned facade와
  `RpcResponseBorrow` in-place ABI, raw lifecycle 전수, published/borrowed drift를 추가로 닫는다. raw bytes는 owner 파일 내부
  `builtin.is_test` helper exact 1곳에서만 읽고 production raw-byte bridge/family decoder caller는 0이며 실제 cross-module decoder allowlist와
  default protocol-failure guard/error·early-return integrated finish는 2c3e가 소유한다. B3-4/5 product-shaped test는 begin-borrow/finish를
  fresh operation 아래 명시적으로 호출한다. 별도 borrow txn type은 0이고 성공 뒤 borrow lifetime은 `RpcResponseBorrow` receipt 하나다.
  ledger→RPC owner만 import하고 owner의 ledger module/type import는 0이며 owner-local neutral
  `AllocationProvenance` scalar로 receipt를 동결한다.
  response-only primitive와 제품 caller는 `.blocking` exact 1 mode만 허용하고 deadline/clock 인자와 무응답 stall fixture는 0이다. socketpair
  peer는 bounded response 또는 EOF를 반드시 발생시키며 deadline SSOT는 2c3e 전에는 열지 않는다.
  완료 증거는 Debug·ReleaseFast exact-count leaf/registry/product/boundary, actual socketpair fragmented response·OOB-before-response·wrong
  kind/id·EOF/truncation, control cap `1/cap/cap+1`·empty와 allocation fail-index, full alias closed set, publish preflight mutation 0,
  accepted owner→borrow→finish reusable 2/64회는 동일 canonical inline slot exact address 하나로 수행하고 finish 반환마다
  `pristine+authority idle+evidence empty`여야 한다. copy/move/cross-binding/same-address ABA, finish callback reentry Busy, safe-free/no-free와
  freed-once drift, `ledger promote→publication preflight+publish permit→ledger-owned RPC transfer(owner seal+entry transferred)→no-fail permit
  consume/authority publish→request
  settle→ledger end→lease release` 및
  정상 경로의
  `finish preflight+txn capture+prepareReleasing permit→owner free_committed→commitReleasingNoFail→node free_call_committed→free→callback 뒤
  owner/finish/evidence revalidation→prepare reusable-authority+evidence-retire+owner-rearm permits→terminal_clean→commit idle→
  evidence empty retire(exact epoch)→commitReusableRearmNoFail(pristine)→operation release` 또는 protocol failure의 permanent terminal, drift 경로의
  `...→terminal_freed_once→authority terminal/fail-stop`(evidence retire 0) source order다. raw authority pointer escape, 기존 attach owner
  변경, production family decoder caller, public generation RPC callsite와 정상 observable product behavior는 모두 0이어야 한다.
  allocation callback/ledger promote 뒤 owner write 전에는 frozen receipt·destination·txn/lease/fence·registry/binding/canonical·authority·
  Client parser/allocator/fd/poison의 exact revalidation을 별도 gate로 고정한다. byte owner의
  `free_committed|terminal_clean|terminal_no_free`와 node/finish-txn의 `terminal_freed_once`는 pointer/allocator zero와 서로 다른
  evidence digest를 직접 검증한다. `terminal_no_free|terminal_freed_once|protocol terminal_clean`만 one-way이고 reusable
  `terminal_clean`은 rearm permit이 소비하는 순간 상태다. source order는
  `finish preflight+txn capture+prepareReleasing permit→owner free_committed(pointer zero)→commitReleasingNoFail→node free_call_committed(epoch)→allocator
  callback→prepare reusable-authority+evidence-retire+owner-rearm permits→owner terminal_clean→commit idle no-fail→
  evidence empty retire(exact epoch)→slot pristine rearm→operation release`
  또는 protocol terminal, callback drift의
  `owner write 0+node/txn terminal_freed_once→authority terminal/fail-stop`이다. begin-borrow preflight는 payload와 그 scope의 fresh
  operation/borrow permit/output receipt storage를 검사하고, finish preflight는 현재 borrow receipt, fresh finish txn, releasing/finish permit과
  operation storage의 exact/partial alias를 전수한다. 종료된 begin-borrow stack 주소의 저장·재검사는 0이며 실패는 capability copy 0·free 0 terminal-no-free다.
  destination까지 invalid한 no-free는 owner write 0, node record `empty`, authority terminal+connection poison으로 닫는다. node
  `RpcFreeEvidenceRecord`는 정상 callback과 authority commit 뒤 operation release 전 exact epoch로 `empty` retire하며 64회 모두 empty를
  재확인하고 stale epoch retire/replay는 mutation 0이다. fail-stop `terminal_freed_once`는 clear/reuse하지 않는다. no-free와 freed-once replay 모두 second free
  0이어야 한다. publication execution txn의 수명은 ledger/lease 정산에서 끝나며 borrow/finish가 이를 재사용하는 callsite는 0이다. RPC
  transfer 뒤 owner/finish의 ledger 역참조는 0이고 frozen receipt
  scalar만 남으며, 기존 attach `transferPromotedResponse`의 signature·결과·free count 변화 0을 differential test로 고정한다. authority의
  named prepare/no-fail consume permit은 final-address·copy/move/replay·wrong-phase를 전수하고 registry 밖 callsite 0을 source oracle로
  고정한다. destination/payload 검증 실패의 4-cell matrix는 destination-invalid owner write 0과 payload-exact safe-free를 독립 단언한다.
  evidence-retire permit은 `client_slot.zig`의 final-address `PreparedRpcFreeEvidenceRetirePermit` exact declaration 하나와
  `{self_addr,record_addr,response_epoch,evidence_digest,free_call_committed_record_seal,consumed_raw}` exact fields를 허용한다.
  callback 뒤 committed record에서만 prepare하고 authority idle 직후 callback/lookup 없이 exact record를 empty로 no-fail consume한다.
  owner-rearm permit은 `rpc_executed_response.zig`의 final-address `PreparedReusableRearmPermit` exact declaration 하나와
  `{self_addr,response_addr,old_identity,old_epoch,expected_terminal_clean_owner_seal,
  expected_consumed_finish_digest,consumed_raw}` exact fields만 허용한다. callback 뒤 current `free_committed` owner+freed-once finish에서
  future seal/digest를 계산해 authority/evidence import나 caller bool 없이 준비한다. client-slot private suffix가 held operation/current binding과
  reusable-authority/evidence-retire/rearm 세 permit의 self address·epoch·digest·canonical lineage를 suffix 진입 전에 한 번에 검증하고
  commit 사이 registry lookup/fallible validation은 0이다.
  prepare/commit rearm leaf의 production direct caller는 그 suffix에서 각각 exact 1이고 `generation_transport.zig` direct caller와 다른 module
  caller는 0이다. owner-file test-only caller는 별도 exact allowlist다. direct zero/reset, public borrow/finish/rearm/reset 노출,
  permit copy/move/replay는 0이며 wrong-order/drift는 reset 0 isolated abnormal exit다.
  callback 뒤 suffix의 reusable-authority/evidence-retire/rearm은 세 permit이다. finish function entry 전체에는 그 셋과 별개로 callback 전
  borrowed→releasing 전이용 authority permit이 필요하므로 releasing authority, finish reusable|terminal authority, evidence-retire, rearm의
  네 permit storage는 client-slot-private `FinishPermitRawStorage` 하나가 aligned `undefined` raw storage로 먼저 예약하고 typed read/write 0을 유지한다. consumed releasing storage를 finish authority storage로 reset/reuse하지 않는다.
  allocator capability capture 전에 payload와 네 permit 각각, permit 상호 간, finish txn/borrow receipt/response owner/
  RegisteredNodeOperation/node/outer owner의 exact/left-partial/right-partial/overflow disjoint를 전수한다. alias는 capability copy·free·
  caller permit init/prepare/commit·owner/authority/connection mutation 0이다. 새 no-permit recovery facade는 0이고 parent-minted
  `permit-alias-preflight-rejected` sentinel 뒤 즉시 strict fail-stop한다. 첫 단계는 sealed response identity와 stored addr/len/digest scalar의
  checked-add만 허용하고 payload 역참조/hash/digest recompute/allocator vtable read-call은 0이다. 네 permit 각각을 payload가 덮어도 해당 raw storage read/write와 payload byte observer 0을
  isolated child로 증명한다. disjoint branch만 bytewise pristine init→permit prepare를 수행하며 source oracle은
  `raw reservation→scalar range preflight→disjoint-only pristine init→prepare` 순서를 고정한다. process가 종료되는 이 exact branch는
  terminal-before-panic graph 게시 요구의 예외다. caller/GUI process만 종료하며 daemon/PTY direct terminate/kill/control frame은 0이다.
  correction isolated child는 host-directed frame/signal 0까지만 증명한다. 실제 daemon product gate는 GUI child fail-stop→EOF-driven client
  detach/revoke exact 1→daemon PID/runtime/PTY child 생존→fresh reattach/output 연속성을 증명한다.
  sentinel capability는 operation 전에 resolve하고 검출 뒤 env lookup/allocation 0+bounded fixed write를 고정한다. disjoint 뒤에만 full
  payload digest/live exact를 허용하고 이후 generic terminal-no-free alias는 raw permit-reservation alias를 제외한다. correction count-5
  evidence/rearm case가 이 inventory를 포함한다. deterministic hostile seam은 네 raw range를 private finish core에 전달하되 별도 lifecycle/
  commit 우회를 만들지 않으며 product wrapper는 실제 local ranges를 전달한다. `FinishPermitRawStorage`는 finish stack의 final-address local
  exact 1로만 존재하고 value return/copy/move/store는 0이다. hostile seam caller는 `builtin.is_test` 또는 test-private wrapper exact
  allowlist뿐이며 production callsite는 0이라는 source oracle을 둔다.
  runtime stage tuple은 `A prepared/E prepared/R prepared → A consumed+idle/E prepared/R prepared →
  A consumed+idle/E consumed+empty/R prepared+owner terminal_clean+finish consumed → R consumed+slot pristine → operation release`다.
  published·borrowed·releasing RPC authority 또는 nonempty free evidence가 남으면 attachment drop은 mutation 0의 `AdminBusy`이고,
  reusable finish 뒤 `authority idle+evidence empty+slot pristine`에서만 다시 허용된다.
  layout gate는 `GenerationTransport.rpc_response` exact-one inline field와 outer-owner inclusion, prepared storage/binding/owner seal/attach
  response와의 exact/partial disjoint, response array/pointer/free-list 0, init pristine, 정상 deinit의
  `slot pristine+authority idle+evidence empty`, permanent terminal의 fail-close 선행, `GenerationTransport <= 2048 bytes` size budget을 Debug·ReleaseFast로 검사한다.
  B3-6 boundary는 client-slot-internal `ResponseDestination=union(enum){attach:*ExecutedResponse,rpc:void}` exact type,
  기존 public `executePreparedRequest(receipt,*ExecutedResponse)` exact signature, generation-transport-file-private
  `executePreparedRpcSubstrate(receipt)`와 `.rpc` wrapper의 inline slot 접근 exact 1, facade 밖 direct slot 접근 0을 고정한다.
  private substrate의 ownership-only settlement exact-one callsite와 actual transport slot 2/64회는 correction gate가 소유한다.
  payload semantic read와 normal `RemoteRuntime` product caller는 0이다. correction부터 client-slot
  module-public entry는 `fail_stop_required`를 return type에 노출하거나 저장하지 않고 기존 private noreturn sink로 즉시 소비한다.
  B3-6은 public facade/semantic decode 변경 없이 peer/resource read 실패의 내부 fail-stop 오분류를 교정하고 같은 strict behavior의
  isolated subprocess/source 증거를 완성한다. owner/capability의 test-only cross-file escape는 0이며 scalar case/nonce/stage-fd hook만 exact 1 허용한다.
  GenerationTransport 제품 facade의 recursive parameter/return과 normal product callsite에서 raw response pointer·slot address accessor·
  borrow·finish·reset은 0이고 normal `RemoteRuntime` family callsite와 사용자 가시 동작도 0이다. 이는 owner/internal client-slot
  declaration까지 프로젝트 전체 0이라는 뜻이 아니다.
  correction 전용 `CR3a-2c3b reusable response correction` artifact는 exact count 5(same-slot 2, same-slot 64, evidence-retire,
  rearm permit drift/replay, post-rearm 금지 동작), B3-6 전용 `CR3a-2c3b internal rpc substrate` focused gate는
  runtime 2+boundary 1, total exact count 3
  (peer-error non-crash actual socket, local invariant fail-stop child, boundary+exact-one callsite)이다. 기존 B3-0a count 4 artifact를
  대신 세지 않는다. 같은 private wrapper에서 peer wire frame/header/envelope malformed·wrong-id·truncated·empty·cap+1·OOM은
  process alive+connection terminal+
  registry response authority permanent tombstone+payload owner pristine+rearm 0+second free 0, local seal/allocator/authority/rearm drift만 abnormal exit여야 한다. runtime permit
  drift/lifecycle tests가 primary이고 source-order tokenizer는 금지된 post-rearm callsite를 보조 검증한다. 두 artifact는 각각
  `/usr/bin/env -i`, 독립 parent-minted pipe capability, inert collector, exact-count zero-test 방지를 적용하고
  `MARU_SESSION_HOST_RPC_REUSE_EXEC|MARU_SESSION_HOST_RPC_SUBSTRATE_EXEC`의 closed 3-mode를 교차 수용하지 않는다.
  bounded nonempty correct-id payload의 JSON/application semantic 오류는 payload semantic read 0인 이 gate가 아니라 2c3e decoder가 소유한다.
  peer matrix의 `empty`는 header 전 zero-byte EOF이며 correct-id zero-length payload도 canonical accepted owner가 아니므로
  process-alive protocol terminal+permanent tombstone+semantic read 0+rearm 0이다. exact cases는
  bad magic, wrong major, invalid kind, wrong request id, declared cap+1, truncated header, truncated payload, zero-byte EOF, 실제 response
  allocation ordinal 전수, correct-id empty payload와 correct response 뒤 coalesced duplicate old-id다. duplicate는 첫 cycle 뒤 다음
  cycle correlation loss로 terminal되고 두 번째 RPC-slot publication/owner-free/rearm 0, parser discard free exact once를 검증한다. 미래 request id의 완전한 response 선송신은
  정상 future response와 wire상 구분 불가능한 compromised-peer 비목표다.
  isolated child는 parent-minted `{version,case_id,nonce,stage}` 11-byte record(`nonce` little-endian)의 case별 exact prefix+final sentinel과 예상 abnormal termination이
  함께 맞아야 한다. response seal/allocator drift는 `free_once` 뒤, authority drift는 permit 준비 뒤, rearm drift는
  `authority_idle -> evidence_retired -> rearm_precondition` 뒤에만 주입한다. stderr marker 단독, exec 126/127,
  capability/nonce mismatch, generic panic, stage 누락·중복·역전은 실패다. stderr/stage pipe는 child 종료 전 동시에 nonblocking drain하며
  capture cap 이후에도 discard-drain하고 overflow/truncation은 실패, absolute timeout 뒤 kill+waitpid exact once를 검증한다.
  B3-0a·B3-0·B3-1·B3-2·B3-3·B3-4/5 correction과 B3-6 internal aggregate strict completion은 완료됐다. B3-6의
  `test-session-host-b3-6`은 Debug·ReleaseFast runtime 2+boundary 1 exact-count를 완료 증거로 소유한다. B3-1은
  Debug·ReleaseFast leaf 4개와 registry 2개, boundary 1개의 exact-count artifact를 완료 증거로 소유한다. B3-2는 Debug·ReleaseFast
  registry 3개와 product 2개, boundary 1개의 exact 11-test artifact를 완료 증거로 소유한다. 모든 내부 gate가
  각 내부 gate가 Debug·ReleaseFast와 boundary에서 함께 green인 상태로 `2c3b-3 완료`로 승격했다.
  다음 문단은 **구현된 C3-2 종료 계약**이다. `test-session-host-2c3d-c3-2`는 C3-1 전체와 Debug·ReleaseFast
  attachment runtime sentinel 8+actual generation `RemoteRuntime` product drain 1+boundary 1을 exact-count로 통과한다.

  C3-2 종료 시 `GenerationTransport`는 SSOT의 exact 15-declaration primitive set(`readAttachmentBatch` 제외,
  `purgeEndedStream` 포함), closed `RuntimeRequest` variants와 exact-field
  `GenerationCapabilities`만 노출하고 arbitrary method-string `call`, generic callback, Client-containing aggregate,
  `*Client|*anyopaque` escape는 0이다. generation의 post-initial batch owner는 2b2 `GenerationBatchAdapter` 하나뿐이며,
  ended purge의 정상 경로와 모든 precommit failure는 exact one-shot receipt로 demux queue만 정리하거나 보존하고 canonical attachment
  drop/lease를 건드리지 않는다. postcommit Client-owned deinit graph drift만 owned allocation을 no-free quarantine하며 borrowed
  ledger/attachment/registry/lease는 이때도 dereference/release/mutate 0이다. 기존 raw
  Client entrypoint는 명시적 legacy union arm에만 격리되고 generation 실패의 legacy fallback은 0이다. recursive signature audit와
  self-address/PID/owner-thread/same-stream cleanup gate는
  copy/fork/reentry를 wire/mutation 0으로 거부한다. initial snapshot은 allocator·binding·stream identity를 봉인한 final-address
  owner와 heap-pinned node canonical permit을 함께 써 exact once free하고 registry accounting에 들어가지 않는다. owner+transport
  stale restore replay, slot 종료 뒤 stale owner의 backing 비역참조 거부, binding splice, allocator free callback의
  same-attachment teardown busy, callback 뒤 permit consume와 batch-internal
  error 비노출을 고정한다. 2c2의 exact signature는
  `purgeEndedStream() -> error{Busy,InvalidOwner,Corrupt,Terminal}!enum{not_ended,purged}`다. Busy/InvalidOwner는 모든 mutation 0,
  committed global latch의 Terminal은 current connection mutation/추가 poison 0, precommit Corrupt는
  demux queue/counter·attachment·lease/registry mutation 0과 connection terminal poison exact 1이며 commit 후 drift-poison은 target cleanup
  완료 뒤 `.purged`로 normalize한다. generation 일반 event loop
  앞의 무인자 `purgeEndedStream`이 exact current binding의 target-stream 첫
  ended만 private receipt로 만들고, ended 부재·foreign stream·non-ended target event에서는 event take/release와 모든 queue mutation이
  0임을 고정한다. `pending_batches`, optional `partial_batch`, 이미 분류된 `pending_stream`, `pending_events` 각각의 단독·혼합 target과
  sibling interleave, 제품 count/byte cap 경계, counter/allocator/event-seal drift를 전수해 prepare 실패 mutation/free 0과 성공 시
  target-only final-zero를 증명한다. `.not_ended` hot path는 작은 target-event peek만 수행해 대형 scratch frame·screen queue scan/hash가
  0임을 계측/source oracle로 고정한다. ended slow helper의 descriptor 배열 cap은 제품 queue cap과 같고, compact target bitset과 queue별
  aggregate payload seal을 사용해 compile-time 전체 `<= 512 KiB`다. target의
  `GenerationBatchRegistry` entry가 reserved/ingress/live/releasing 어느 상태로든 존재하면 `busy`이며 registry/token/OwnedBatch/accounting,
  parser raw RX/framing, attachment pending lease/screen, cleanup registry와 connection lease는 정상 경로와 모든 precommit failure에서
  byte-for-byte 불변이다. postcommit drift에서는 Client-owned parser allocation만 no-free로 버리고 borrowed authority는 불변이다.

  commit은 immutable target descriptor scalar에 대한 cleanup authority를 취득하되 slot bytes를 overlay하지 않고, 별도 small cursor를
  callback 전에 advance해 exact-once를 소유한다. 별도 full-size 배열은 0이며 `EndedPurgePreparation.sealForCommit`과 네
  queue stable compaction·최종 counter publish가 첫 free callback보다 앞섬을 callback 관측으로 검증한다. receipt copy·wrong
  thread·same-address replay·binding/slot/node/transport splice, commit 직전 queue
  drift, first/middle/last free callback의 public API 재진입은 attachment/slot/client mutation `busy`와 sibling 순서·bytes·counter 보존을
  Debug/ReleaseFast production-type test로 증명한다. 2c1의 snapshot 전용 permit/active fields/registry를 kind-tagged 공통
  `StreamOperationPermit`/단일 active-operation tuple로 migration하고 snapshot↔purge 상호 busy, teardown 및 sibling을 포함한
  input/event/RPC/queue mutation busy, immutable scalar 관측만 허용을 고정한다. hostile raw sibling backing drift는 복원을 주장하지 않고 callback 뒤 detect+poison,
  target descriptor는 callback 전에 전부 freeze되어 exact once free됨을 고정한다. node permit은 마지막 callback과 post-callback 검증까지
  live이다. callback 중 canonical queue/source reread는 0이고 마지막 callback 뒤 frozen survivor descriptor/range seal과 current
  queue ownership metadata를 비교하는 post-validation은 정확히 한 번뿐이다. 구조 drift면 payload pointer를 역참조하지 않고 canonical
  Client-owned deinit fields를 empty/null로 tombstone하고 quarantine commit+trusted receipt consume으로 pointer-free proof를 발급한 뒤
  absorbing `quarantined_no_free` poison fields와 `PreparedEndedPurgeCommit` consumed를 게시하고 terminal fence를 마지막으로 publish해 generic teardown의
  pointer/allocator/fd read와 free/close를 0으로 만든다. drift의 exact
  suffix 순서는 `all target cleanup -> Client-owned deinit tombstone -> Registry.commit(+CommitReceipt) ->
  Registry.consumeCommitted(+ConsumedCommitProof) -> no-free poison + PreparedEndedPurgeCommit consumed -> terminal fence -> node permit ->
  EndedPurgePreparation transport receipt`이다. 어떤 postcallback drift에서도 fd close는 0이다. callback 전
  process-global `idle->reserved`와 blocking generation Client complete owned extent checked sum `<= max_ended_purge_quarantine_bytes(64 MiB)`, 정상 release, drift exact-once
  `reserved->committed`, replay charge 0, committed 뒤 새 generation Client/reconnect/purge terminal 거부를 검증해 process 누적을 한 건으로
  고정한다. deinit owner SSOT는 `build_id`/Client lifecycle/pending outbound와 slice payload의 exact owned length, parser/list/partial capacity backing을
  포함하고 borrowed ledger/attachment/registry/lease는 제외한다. external mode는 callback 전 mutation 0으로 거부한다. cap 초과는
  callback/free/quarantine 0인 precommit no-cleanup poison이 reason/unusable을 latch하고 validated captured fd만 detach+close한 뒤 later ordinary
  deinit이 intact owner를 회수한다. 이후 drift generic teardown의 pointer/allocator/fd read와 free/close가 0임을 hostile
  allocator oracle로 고정한다. 구조가 일치할 때만 aggregate payload seal을 재계산한다.
  commit 전 typed error는 mutation 0, commit 뒤 정상/poison은 모두 target cleanup과 no-fail node permit→transport receipt suffix를 끝내고
  public `.purged`로 정규화하며 poison latch를 별도로 검증한다. purge 뒤 attachment state·cleanup registry·connection lease가 live이고 later
  `GenerationAttachment.tryDeinit`만 registry release·attachment drop·lease cleanup의 canonical 권위이며 raw demux 재정리는 idempotent
  no-op임을 source/boundary oracle로 분리한다.
  no-wire local OOM, complete snapshot apply OOM, malformed payload, partial/timeout/EOF, detach
  prepare OOM, success, invalid_request/unauthorized/conflict reject와 detach reply-loss 상태표를 actual
  socket/fail-index로 전수한다.
  모든 success/errdefer/map-put/terminate/detach 경로는 `pool retain -> prepared binding -> runtime publish`와
  `live admission close -> registry settle/handoff -> lease release -> RemoteRuntime destroy -> pool release` 순서를 exact once
  지킨다. fork child의 prepared abort/commit, live method, registry token, permit consume는 callback/wire/free/registry mutation 0이고
  strict 제품 wrapper만 fail-stop한다.
  reconnect/current
  publish/retired node 생성, incident/artifact mutation과 AppSession 동작 변화는 0이며
  real socket은 2e parity gate이고 AppKit은 완료 조건이 아니다. uncertain/malformed accepted attach response는 local reservation
  abort 뒤 connection close로 server subscription final-zero가 된다. 2a는 neutral contract leaf와 GUI shell+transport 최소 core의
  실제 attach/deinit/drop/lease, external owner-schema digest, 2b는 실제 pump의 buffered/direct→registry transaction·두 cap·release와
  generation GUI batch 경로의 raw AttachmentTransport Client context와 raw Client 경유 batch read/release/drop callsite 0을
  증명한다. 2b의 상태는
  **2b1(node batch registry와 Client transferred accounting, 구현) → 2b2(GUI node-bound adapter와 제품 pump/release/canonical drop 무회귀, 구현)**로
  나누며, 2b1만 green이어도 GUI raw context가 남아 있으므로 2b 전체를 구현으로 표시하지 않는다. 2c는 남은 exact primitive facade와
  `RemoteRuntime.client`를 포함한 raw escape zero,
  2d는 2d1 actual generation release 결과와 최초 retry 보존(구현 완료), 2d2 aggregate terminal handoff와 typed node
  teardown(구현 완료), 2d3 permit/reentry/quarantine/proof-loss 제품 경계(구현 완료) 순으로 닫았으므로 2d 전체가 완료됐다. 2e는 actual socket
  attach/pump/deinit/uncertain/malformed/snapshot-failure/failed-release fixture와 전체 source
  boundary를 각각 증명한다. 각 gate는 production-type unit과 boundary를 재실행하며 전체가 green이기 전 CR3a-2 완료를 주장하지
  않는다.
  2d1 focused gate는 Debug·ReleaseFast 각각 registry result/permit 4개, ClientSlot actual release 3개,
  GenerationAttachment actual retry/teardown 1개인 unique component exact 8개와 boundary 1개를 실행한다. retryable은 exact
  registry/token test owner seam이 permit decision에서만 발행하고 제품 경로는 그 결과를 그대로 전달한다. retryable 전후 payload,
  token, accounting과 Client sibling queue는 보존되고 teardown의 새 permit 성공 뒤 target free와 accounting consume은 exact 한 번이다.
  2d2 focused gate는 2d1을 상속하고 Debug·ReleaseFast 각각 neutral handoff 3개, registry aggregate 4개,
  RemoteAttachment trigger/tombstone 3개, ClientSlot typed teardown 3개, GenerationAttachment actual terminal handoff 1개인
  unique component exact 14개와 boundary 1개를 실행한다. ordered lease view의 0/1/4,096행과 preflight fail-index는 allocation과
  source mutation 0을, second retryable/first indeterminate는 하나의 node-final receipt publication을, surviving descriptor는
  free/accounting exact once를, authority가 불명확한 descriptor는 never-free quarantine을 증명한다. external lease 혼합,
  copied/stale/cross-node receipt와 partial source tombstone은 모두 제품 callback/free/node mutation 전에 거부한다.
  public bulk registry commit은 0개이며, node-final streaming publication 뒤 state seal이
  `published→draining→consumed→terminal`로 진행한다. 첫 indeterminate는 deinit에서 release callback을 재호출하지 않는다.
  2d3은 구현됐다. focused gate는 Debug·ReleaseFast 각각 final-address continuation 3개, callback reentry 3개,
  preflight/exact-once suffix 3개, quarantine 2개, 실제 attachment final-zero 1개인 unique component 12개와 fresh-exec
  subprocess 3개, boundary 1개를 실행한다. pre-callback drift는 free 0, post-callback drift는 free exact 1 뒤 공통
  `fatalIntegrity(.proof_loss)` exit 86이며 두 경우 모두 accounting/row/handoff completion/node destroy 0을 증명한다.
  2b1의 현재 자동 증거는 node-local 4,096-entry registry와 독립 exact accounting ledger, 18 MiB pending+transferred 합산,
  pointer-free token의 registry incarnation·entry generation·stream 결속, buffered/direct-parser all-or-none transfer,
  0/1/4,096/4,097 및 exact cap/cap+1, allocator fail-index·drift·partial rollback, sibling/source/canonical owner alias,
  duplicate/replayed receipt와 generation exhaustion을 production `ClientNode` 타입으로 검증한다. guarded allocator의
  alloc/resize/remap/free callback에서는 같은 thread의 same/foreign `ClientSlot` read/release/deinit을 registry generation·entry,
  ledger charge, queue, wire mutation 전에 busy로 거부한다. 모든 batch release callback은 nested release/deinit을 막고, buffered
  callback의 read는 exact pending sibling만 허용하며 miss는 reserve·socket/parser 전에 busy로 닫는다. socket-ready miss frame이
  callback 뒤 정상 소비되는지와 direct/buffered payload release callback 뒤 token·payload 보존 및 정상 cleanup,
  allocator/parser descriptor 복원 뒤 일반 RPC prepare→abort→settled까지 실행한다. Debug·ReleaseFast·boundary와 전체
  `mise run check`가 자동 gate다. 이 증거는 GUI `GenerationAttachment`의 실제 pump adapter나 raw context 제거를 포함하지 않으며
  그 범위는 2b2, 전체 actual-socket parity는 2e가 소유한다.
  2b2 red/green oracle은 `GenerationAttachment`이 inline final-address batch adapter를 소유하고 `commitAccepted`
  generation branch에 legacy transport 인자·fallback이 0인지, `.generation` token이 external `.charged`와 혼용되지
  않는지, post-initial buffered/direct batch가 실제 GUI pump에서 borrow/release exact once로 정리되는지를
  production type으로 실행한다. teardown은 read admission을 먼저 닫고 release-only draining으로 pending token을 전량
  settle한 뒤 기존 2a canonical drop/lease release를 한 번만 수행한다. generation release invariant 실패는 generic
  `failed_release`에 보존하거나 sibling으로 계속하지 않고 strict fail-stop하며 retryable/indeterminate는 2d 범위다.
  source boundary는 legacy-only `attachmentTransport(*Client)` raw cast 3개와 initial snapshot/event/input/RPC allowlist를 그대로
  두되 generation commit/pump의 raw Client context/cast는 0, `readGenerationBatch|dropBufferedStream`은 `client_slot.zig`만의
  canonical caller로 고정한다. `RemoteAttachment` 7-field outer schema, external `Prepared|Attached`, `ExternalPumpStorage`
  owner graph와 legacy `.untracked|.charged` 의미는 불변이고 `AttachmentBatchLease.generation` 추가에 따른 union layout 변화만
  허용한다. Debug·ReleaseFast·boundary·전체 check를 재실행하며 actual-socket 전체 failure parity/AppKit은 2e/CR6 범위다.
  현재 2b2 자동 증거는 buffered idle·2-token FIFO/compaction·queue append OOM·malformed apply의 token exact release,
  실제 socketpair direct-parser snapshot pump, pending generation token의 release-only drain 뒤 canonical drop, adapter copy·foreign slot·
  wrong-thread의 mutation-before rejection을 production type으로 실행한다. boundary는 generation commit의 legacy transport 0,
  adapter mint sole caller, legacy fallback 1곳, 2c initial snapshot/ended-event raw allowlist 각 1곳과 ClientSlot raw batch/drop sole
  caller를 고정한다.
  2a의 현재 자동 증거는 canonical node-local transport/response seal, opaque prepared request storage, final response의
  binding/transport/request backing non-alias preflight, wire 전 allocator capture와 Frame schema 불변 out-parameter 기반의 frame별
  실제 payload allocator 일치,
  OOB queue callback의 captured-allocator 사용·같은 thread의 foreign Client까지 wire 전 동기 재진입 거부·drift 복원,
  GUI parent/node owner payload alias의 no-free fail-stop,
  live-seal registry erasure 거부,
  copy/ABA/reentry·poison-before-free·snapshot EOF rollback을 production type으로 실행한다. 실제 daemon의 기본
  attach/detach/reattach도 포함하지만 2e가 요구하는 전체 socket failure/parity matrix를 대신하지 않는다.
- CR3b: pool-membership과 독립된 connection generation 전이·publish·overflow, stale callback/동시 attempt,
  R1 admission close/cancel → R2 store-only detach+placeholder publish+callback cleanup → R3 final seal/canRetire/tick-end destroy의
  three-phase retirement, retired Client cap 2. CR3c: 실제 RemoteGeneration slot integration.
  R1은 production `ClientSlot`의 generation 1을 대상으로 closed-operation `withCurrent` stack borrow와 final-address
  `PreparedAdmissionClose`를 검증한다. open/mismatch/active borrow/commit 후 closed/cancel 후 reopen, copy·wrong-thread·fork·request replay와
  callback reentry를 Debug·ReleaseFast에서 실행하고, raw `HostAdapter.logicalClient()` 제품 caller와 reconnect publish/current flip/
  retired node/destroy/generation increment는 0으로 고정한다. focused gate는 각 최적화 모드에서 ClientSlot component 6개,
  HostAdapter 제품 facade 1개, source boundary 1개를 exact-count한다.
  R1은 current pointer·runtime/screen target·connection generation을 바꾸지 않는 inactive 기반이라 CR2보다 먼저 허용된다.
  R2 admission은 CR0b·CR1·CR2a~e의 focused gate가 모두 green이고 CR2의 production `RemoteGeneration`, stable proxy,
  preallocated `UnavailableCore`, `PreparedReconnect`가 존재해야 한다. R2가 이 네 기반을 대신 구현하는 것은 선행 gate 우회다.
  R2는 R2a(callback-free proxy unavailable+detached tombstone atomic publication), R2b(final-address cleanup handle exact-once),
  R2c(새 Client node+checked-monotonic current publication)로 나눈다. R2a는 fd/allocator callback·current 교체·destroy 0,
  R2b는 새 generation publish 0, R2c는 old destroy 0을 각각 source boundary와 production-type unit으로 고정한다.
  R2a focused gate `zig build test-session-host-cr3b-r2a`는 CR2e-e3c3을 상속하고 최적화 모드마다 actual socket을 가진
  `RemoteGeneration` 성공 1행, wrong-generation mutation-0 1행, stable proxy reader exclusion 1행, Client invalid-raw
  fail-close 1행, source boundary 1행을 exact 실행한다. 성공 행은 stable proxy
  writer gate 뒤 unavailable generation과 Client detached tombstone generation을 exact `+1`로 결속하고 fd·poison 상태·connection
  generation을 보존한다. 진단 projection은 test-only conditional facade이며 shipping reader authority를 추가하지 않는다.
  R2a 제품 caller는 0이고 R2b가 caller-owned final-address cleanup handle을 별도로 도입하기 전에는 fd/attachment 정산을 주장하지 않는다.
  R2b focused gate `zig build test-session-host-cr3b-r2b`는 R2a를 상속하고 최적화 모드마다 actual fd+pending frame exact-once
  cleanup 1행, external-mode reserved cleanup 1행, copied/wrong-generation mutation-0+abort/reopen 1행, ClientSlot invalid-raw/copy/Client-owned-allocation-alias
  fail-close 1행, source boundary 1행을 exact 실행한다. final-address keyed handle은 fd, pending frame address/length/stream/offset,
  allocator provenance와 external reservation을 봉인하고 writer gate에서는 Client fd/pending owner만 callback 없이 이동한다.
  external cleanup과 close/free는 gate 밖에서 수행되며 제품 caller는 0이다. R2c focused gate
  `zig build test-session-host-cr3b-r2c`는 R2b를 상속하고 최적화 모드마다 final-address 새 Client node, checked `generation + 1`,
  usable live fd preflight·registry/current atomic publication·old detached node 보존·stale generation reject 성공 행과 copied-handle/candidate-digest drift
  abort/old-registry 복구·
  max-generation checked-add mutation-0 행,
  HostAdapter compatibility facade와 source boundary를 최적화 모드마다 `2+1+1`로 exact 실행한다.
  managed incident binding과 게시 뒤 첫 attachment reservation은 새 Client 주소/generation에 exact 결속하며 제품 caller와
  old destroy는 0이다. R3 reclaim과 CR3c ordered integration은 아래 focused gate가 소유하며 actual socket은 CR4다.
  R3 focused gate `zig build test-session-host-cr3b-r3`는 R2c를 상속하고 최적화 모드마다 exact 2-slot retired inventory,
  generation 1→2→3 publication, cap 2의 세 번째 prepare mutation-0 reject, pure Client readiness, final-address reclaim seal,
  generation 1 첫 tick 뒤 generation 4 게시와 generation 2→3 tick destroy/final zero 성공 행 1개, copied/stale/digest-readiness drift destroy-0 행 1개, HostAdapter tick-end
  facade 1개와 source boundary 1개를 `2+1+1`로 exact 실행한다. reclaim suffix만 Client/registry/accounting teardown과 allocator
  destroy를 소유하며 current와 sibling retired는 보존한다. 이 facade의 sole 제품 caller는 CR3c2 owner이며 CR4 actual socket은 미완료다.
  CR3c는 R2/R3의 결과를 이미 존재하는 `RemoteGeneration` slot에 연결하며 stable shell 최초 도입을 소유하지 않는다.
  CR3c1은 prepared admission close 아래 old attachment를 먼저 terminalize하고 admission close를 no-fail 게시한 뒤 R2a/R2b/R2c를 진행한다.
  R2c가 게시한 receipt와 같은 adapter/old-next connection generation을 공유하는 forward-recovery `PreparedReconnect`를 stable screen writer
  gate에서 게시한다. R2a unavailable placeholder와 candidate는 같은 shell generation을 쓰되 connection generation은
  별도 필드로 결속하고 두 old owner를 각 기존 세대의 retiring으로 보존한다. mismatch/copy/drift는 RemoteGeneration/screen
  mutation 0이며 이미 게시된 Client graph를 보존한다. CR3c2는 matching retiring RemoteGeneration attachment를 먼저 정산한 뒤 oldest retired Client를 같은 tick-end
  turn에서 회수하며 generation mismatch의 destroy 0과 final zero를 검증한다. focused gate
  `zig build test-session-host-cr3c-c2`는 정상·hostile 2행과 source boundary 1행을 Debug·ReleaseFast에서 exact-count한다.
  prepared authority는 PID/process nonce와 owner·slot·node incarnation을 검증하고 terminalized old attachment만 admit한다.
  중간 test-only transcript는 실제 RemoteGeneration inventory가 먼저 0이고 Client retired inventory는 아직 1인 상태를 관측한
  뒤 둘 다 0이 되는 순서를 고정한다. CR3c production-type 구조 integration은 구현됐으며 actual socket E2E는 CR4다.
- CR3a-2e(구현 완료): generation attach는 wire write 전에 final-address binding, cleanup row, connection pin, batch adapter를 전부
  준비한다. batch adapter는 `reserved(stream_id=0)`에서 시작하고 accepted response의 exact nonzero stream만 callback/allocation 없는
  suffix로 결속해 `live`가 된다. Debug·ReleaseFast `test-session-host-2e`는 준비 계약 4개, actual socket parity 6개, rollback 4개,
  boundary 1개를 실행한다. actual socket 행은 성공, typed reject, response 전 EOF, accepted 뒤 snapshot EOF, malformed accepted,
  initial snapshot apply 실패를 다루며 wire 전에 모든 준비가 끝났는지와 성공 뒤 cleanup row/pin/batch identity가 같은 stream에
  결속되는지를 증명한다. rollback 행은 준비 fail-index, typed reject, uncertain response, accepted 뒤 snapshot 실패가 pin/row/batch를
  exact zero 또는 단일 committed cleanup으로 수렴시키는지 검증한다. `ExternalInboxLedger` import/caller, reconnect/current 교체,
  retired node publication, incident/artifact mutation은 0이다.
- CR4는 실제 socket gate 세 개다. CR4a prerequisite는 CR3c의 unavailable shell과 이미 게시된 fresh Client replacement를
  같은 `HostAdapter`에 결속한 observer attach+initial snapshot을 검증한다. typed reject는 candidate authority만 정산하고
  published Client를 usable로 보존하며, EOF는 같은 node·generation을 보존하되 transport를 fail-close한다. CR4a
  screen wire prerequisite는 initial snapshot sequence 0, 이후 resync/fallback snapshot과 delta exact +1 및 queue-admission 뒤 host commit을 제품 projection/server 행으로
  검증한다. host frontier 제품 행은 core-lock projection receipt와 fixed barrier-last batch를 실제 subscription queue에 admit한 뒤에만 base/frontier와 pending→admitted를 함께 commit하고 copied/PID/process-nonce/Client-address/ConnectionKey/thread drift, prepare rollback과 global queue-pressure 거부의 prefix/base/frontier/pending mutation 0을 검증한다. 화면 변화가 없는 turn도 idle 성공이 아니라 barrier-only batch exact 1을 admit하며 preparation allocation fail-index는 성공점까지 pending/frontier mutation 0을 유지한다. actual socket fixture가 snapshot 0→delta 1→exact barrier에서 final-address receipt를 만들고 gap·malformed delta·batch/cell cap+1·missing barrier는 receipt 0과 새 Client fail-close로 닫는다. byte cap은 product apply leaf에서 마지막 초과 batch 적용 전 회수와 accounting mutation 0을 고정한다. bounded actual issuer caller는 실제 manifest/socket Client를 backend job으로 이동하고 같은 adapter replacement와 observer candidate/staged receipt를 exact once 게시하며 connect부터 barrier까지 같은 absolute deadline을 공유한다. deadline 만료는 candidate 전 sealed failure와 Client fail-close이고 만료된 staged receipt는 consume 0·cleanup 가능이다. allocator fail-index 제품 행은 connect/job, replacement preflight/node, observer/snapshot/delta/staged receipt를 첫 성공+1까지 순회하고 매 반복의 retired Client·registry·pin·batch·barrier inbox와 allocator bytes final 0을 확인한다. 이 증거는 local idle을 caught-up으로 승인하지 않으며 이 행까지 CR4a 완료로 센다. bounded actual issuer는 실제 daemon manifest/socket에서 `connectExistingHostUntil`을 호출하고 fresh Client를
  final-address `RemoteTermBackend` job에 exact once 보존한 뒤 same-adapter replacement와 observer candidate/staged receipt를 게시한다. replacement node OOM은 unavailable shell과 owned Client를 sealed forward-failed state로 보존하고 rollback·재시도를 거부한다. connect/hello에서 시작한 absolute deadline은 attach/snapshot/delta/barrier까지 동일하며 만료된 receipt는 cleanup만 허용한다. replacement 게시 전 실패는 old graph mutation 0이고 게시 뒤 실패는 unavailable shell과 새 Client generation을
  보존한다. typed reject state는 request nonce와 usable projection을, candidate connection-failure state는 exact poison reason과 fd=-1/unusable/first-reason projection을 함께 seal하고 state/reason drift를 mutation 0으로 거부한다. CR4b는 mutation seal 아래 status/takeover를 exact once 실행하며 takeover
  reply-loss에는 local authority를 발행하지 않고 candidate close 완료를 가정하지 않는다. direct-controller grant만 기다리고
  observer conflict는 자동 탈취하지 않는다. CR4c는 proven candidate를 CR3c publication/reclaim에 연결한 뒤 새 generation의
  input과 forced first resize를 검증한다. CR4a만 green이면 takeover·publication·사용자 가시 reconnect는 미완료다.
  actual-issuer 제품 행은 `RemoteTermBackend.HostReconnectJob`을 유일 owner로 사용하고 AppSession/RemoteRuntime의 direct
  connect caller를 0으로 유지한다. 현재 실제 manifest/socket host당 connect 1회, job-owned Client와 same-adapter replacement exact once를 검증한다.
  이어 observer candidate와 staged receipt 1회를 연결하고 connect/hello/snapshot/delta/barrier가 같은 absolute deadline을 공유하는지 확인한다. connect 전 실패는 pool과
  old graph mutation 0, publication 뒤 allocator fail-index·deadline·wire failure는 candidate/receipt 0, exact current
  node/generation 보존, Client fail-close와 registry/pin/batch/resident ledger final zero를 증명한다.
  dependency-neutral contract prerequisite는 host process/subscription identity와 client request nonce wire DTO 및 MRSH kind/header를
  고정하고, host issuer가 이를 소비하되 generic unsealed subscription batch admission은 0으로 유지한다. catch-up barrier host prerequisite는 capability 없는 발행 0, subscription/runtime/ConnectionKey/request nonce가 결속된
  pending row, core-lock projection receipt, barrier-last single-batch admission을 요구한다. queue cap/OOM/rollback은 queued
  prefix 0과 base/frontier/pending mutation 0이고 admission 뒤 동일 request nonce retry는 projection/queue/frontier commit exact1,
  target 불변, spent replay mutation 0이다. 실제 fork child는 inherited mutex 접근 전 OS PID/process seal mismatch로 거부한다.
  client prerequisite의 첫 slice는 raw fd reader 0과 negotiated capability, 기존 Client demux를 통한 sibling screen/barrier 보존, absolute deadline과 exact identity 소비를 제품 테스트로 고정한다. 이어지는 `GenerationAttachment` slice는 catch-up 전용 batch 64개/encoded 16 MiB/decoded cell 1,048,576개 상한을 일반 inbox cap과 분리한다. target exact equality와 gap/malformed/batch·cell cap+1/missing barrier의 receipt 0을 제품 socket에서 검증하고 byte cap leaf도 apply 전 mutation 0으로 닫는다. actual `connectExistingHostUntil` E2E, backend-owned Client job, same-adapter replacement, observer candidate/staged receipt와 allocator fail-index/final ledger 0까지 구현돼 CR4a를 완료로 센다.
- CR4c C1+C2는 부분 구현이다. C1 Debug·ReleaseFast actual backend job이 CR4b의 `controller_evidenced` receipt만 소비해 observer
  cleanup registry RPC identity, transport binding과 attachment-local role을 동일 controller generation으로 승격한다.
  final-address preflight/no-fail owner chain과 외부 product caller 0을 boundary로 고정하고, success 뒤 stable shell unavailable,
  mutation seal 불변, candidate active, public input Unauthorized와 generation publication·forced resize·reclaim 0을 확인한다.
  C2 actual backend success는 candidate 전용 forced-first-resize exact 1, CR3c stable screen+RemoteGeneration publication exact 1,
  reconnect executor+mutation owner generation 전진, 새 generation input exact 1, RemoteGeneration-first/retired-Client-second
  reclaim과 job/candidate/stage final zero를 실행한다. expired resize 행은 publication/input 0, new Client fail-close와 sealed
  mutation digest 보존을 실행한다. 별도 actual socket 행은 forced resize success/stale/wrong-size/EOF/OOM과
  peer-contract/transport/local-resource first poison provenance를 구분한다. copied/moved
  job·stage, adapter/runtime/generation/controller drift, cleanup binding splice, resize reject/EOF/OOM/deadline을 닫는다.
  publication suffix controller-generation drift는 actual host job subprocess의 common proof-loss exit 86과 유계 process-group/
  artifact 정산으로 검증한다. 이 행까지 green이면 CR4c 단일 Window real-socket reconnect를 완료로 센다. 실제 AppKit 수동 사용과
  멀티윈도우·다중 runtime은 각각 CR5/CR6 전까지 완료로 세지 않는다.
- CR5: 2 Window·다중 runtime, k번째 authority commit 장애의 runtime ledger/forward resolution, Window move/close 경쟁,
  reconnect job 자체의 workspace write·host/runtime spawn·upgrade 시작 0. positive terminate confirmation을 받은 사용자
  close transaction만 pane/binding 제거 checkpoint를 정확히 1회 쓴다. pending/unconfirmed 상태에서 Window close는 binding을
  제거하되 runtime terminate 0이고 다음 inventory에서 Recovered Sessions로 노출한다. Take Control tuple의 double-click/move/close/TTL/generation 경쟁은
  takeover 송신 최대 1이고 stale action은 0이다.
- 모든 CR 결과는 `model-only | production-type unit | real socket | real AppKit` 증거 수준을 기록한다. CR2/CR3 완료는
  production type import test가 필수이며 임시 PoC green만으로 닫지 않는다. `ReconnectReducer`는 모든 legal transition과
  illegal state/event pair fail-close를 model-based sequence로 검증한다. 3-runtime `published_new + frozen_unavailable + ended`
  혼합 결과에서도 성공 generation publish, unavailable placeholder 전환, old attachment/screen/Client retirement가 유한
  시간에 끝나야 한다. placeholder는 shell-embedded bounded `UnavailableCore`만 사용하고 old
  grid/scrollback/selection/search/link/image backing은 0이며 Retry full snapshot이 새 screen을 구성해야 한다. store-only
  detach commit 중 callback/allocation 0, finish cleanup exact once와 실제 placeholder marker/title/runtime ID를
  production-type/headless render로 검증한다.
  첫 CR5a prerequisite는 이 제품 전이를 임의의 병렬 enum으로 다시 만들지 않고 CR2e의 `RuntimeLedger`, `LocalState`,
  `MutationState`를 그대로 사용하는 pointer-free runtime-set validator로 시작한다. canonical set은
  `{job_generation,host_id,pool_membership_generation,expected_connection_generation}`과
  runtime handle/address/generation/runtime ID/shell generation을 결속하고 handle 순 정렬과 handle/address/runtime ID 유일성을 요구한다.
  terminal summary는 같은 host-job identity, 세 local terminal count와 retry reservation만 pointer-free로 내보내며 제품 caller는 0이다. 이 값 계약의
  green은 backend `HostReconnectJob`이 여러 runtime을 소유하거나 실제 Window를 게시했다는 증거가 아니다.
  CR5b-1은 이 caller-zero 경계를 처음 해제한다. `RemoteTermBackend.beginHostReconnectConnect`가 manifest/socket I/O보다 먼저
  같은 host의 runtime 행을 정렬·봉인하고, final-address job이 최대 4,096행 inline backing과 content digest를 exact once 소유하며
  `@sizeOf(HostReconnectJob) <= 512 KiB`를 지켜야 한다. 3-runtime
  + sibling-host fixture, 빈 집합, allocation fail-index, copied job, runtime add/remove와 handle/address/generation/runtime-id drift는
  Client publication과 runtime mutation 전에 reject·final zero여야 한다. 이 증거는 runtime-set 제품 owner의 capture만 닫으며,
  행별 observer/takeover/publication, k번째 실패 forward resolution과 Window 경쟁은 CR5b-2 이후 증거다.
- CR5b-2는 공유 Client를 runtime마다 교체하는 루프를 허용하지 않는다. CR5b-2a gate는 3-runtime host job에서 각 old
  attachment와 stable-screen unavailable publication authority를 모두 먼저 준비하고, 1/2/3번째 Busy·corrupt·identity drift,
  copied/moved prepared owner와 runtime add/remove에서 전 runtime screen/attachment, ClientSlot, ledger mutation 0과 prepared owner
  final zero를 증명한다. CR5b-2b gate는 전 행의 prepared authority를 재검증한 뒤 unavailable 전환 전체와 shared Client
  retirement/replacement exact 1을 한 owner-turn no-fail suffix로 실행하며, sibling attachment가 남은 동안 Client deinit 0,
  final unavailable count=total, old Client cleanup exact 1을 검증한다. replacement node allocation과 identity 발급은 suffix 전
  reserved preparation에서 끝나야 하며, fail-index는 runtime/Client/screen mutation 0과 fresh Client job ownership 보존을
  확인한다. commit hostile은 copied/moved/replayed reservation과 sealed slot/old-node/job generation drift를 첫 runtime mutation 전에
  거부하고, 첫 runtime commit 이후 proof drift는 common proof-loss로만 끝나는지 확인한다. suffix 안의 allocation/callback은 0이다.
  CR5b-2c gate는 같은 published replacement receipt를
  runtime별 CR4 transaction이 소비한다. 제품 socket 표는 3-runtime success 및 shared Client를 fail-close하지 않는 k번째
  `authority_conflict`에서 앞선 성공 rollback 0,
  잔여 runtime의 finite forward resolution, `published_old=0` terminal summary와 final registry/pin/batch/allocator 0을 검증한다.
  cursor는 handle 정렬 순서로만 전진하고 한 시점의 active CR4 scratch는 exact 1이다. success 행은
  `new_controller_evidenced/published_new/open`, 현재 conflict 행은 exact `authority_conflict/frozen_unavailable/closed`, untouched
  suffix는 `old_valid/frozen_unavailable/closed`로 닫는다. allocation-free cursor 계약은 typed reject·takeover unknown·ended
  disposition도 canonical row로만 투영한다. CR5c gate는 첫 success 뒤 deadline으로 shared Client가 fail-close되는 실제 socket
  행을 이어 받아 published prefix의 retirement를 전부 prepare한 뒤에만 all-row unavailable no-fail suffix를 실행한다.
  published prefix는 `new_controller_evidenced/frozen_unavailable/closed`, untouched suffix는
  `old_valid/frozen_unavailable/closed`이고 summary는 `published_new=0`, `retry_reserved=total`이다. 전 runtime input 0,
  두 번째 runtime preflight lookup 실패에서 앞선 prepared owner abort와 job/row mutation 0 뒤 clean retry, terminal
  runtime/retired Client/replacement receipt의 retry-job 결속과 backend teardown runtime-first 정산, replay 거부를 검증한다.
  k=1/2/3 conflict 표는
  앞선 success generation/screen/mutation projection의 bytewise 불변, 뒤쪽 status/takeover/resize/publication wire 0, summary seal 뒤
  replay/copy/cursor·row·replacement drift mutation 0을 확인한다. 첫 success 뒤에도 job/replacement는 live이고 마지막 row terminal
  summary 뒤에만 exact once 정산된다. summary 작성과 row 전이는 기존 inline backing에서 allocation/callback 0이어야 한다.
  all-success에서는 각 runtime의 retiring generation을 먼저 없앤 뒤 shared retired Client를 마지막에 exact once 회수하고
  replacement receipt를 tombstone한다. failure summary의 `frozen_unavailable` 행은 아직 terminal attachment가 shared retired
  Client를 참조하므로 `retry_reserved` receipt/Client를 job에 유지하며, backend 최종 정산은 runtime owner를 먼저 파괴한 뒤
  Client를 회수한다. 두 경로 모두 Client-before-RemoteGeneration 파괴는 0이어야 한다.
  CR5c까지 green이어도 실제 2 Window move/close 경쟁은 CR5의 다음 Window gate 전까지 완료로 세지 않는다.
  CR5d-1은 CR5c terminal summary와 canonical runtime rows를 소비하는 final-address Window owner/transaction을 추가한다.
  두 Window에 걸친 binding은 runtime handle 순으로 정렬되고 `{window address, AppSession generation, graph generation,
  runtime handle/generation, surface id}`가 모두 유일해야 한다. fresh action은 action generation과 absolute expiry를
  transaction에 봉인하며 at-1만 admit하고 exact/+1은 expired-spent다. owner는 active/spent action generation을 보존해
  동일 action으로 별도 transaction을 다시 발급하지 않는다. copied/moved/replayed transaction, 동일 action의
  double-click, Window 이동/close, runtime/job/summary drift는 topology·binding·takeover/terminate wire mutation 0이다.
  이 prerequisite의 제품 caller는 0이며 CR5d-2가 실제 AppSession move/close와 close reducer를 연결하기 전에는
  2 Window 제품 완료로 세지 않는다.
- CR5d-2는 backend terminal job에서 runtime generation을 다시 얻어 두 AppSession의 실제 Term binding과 CR5d-1
  transaction을 결속한다. 기존 `moveWorkspaceToSession`으로 target Term을 다른 Window에 옮긴 뒤 옛 action을 실행하는
  행은 stale reject와 양 Window topology·reducer·takeover/terminate wire mutation 0을 확인한다. close success는 실제
  `termination_unconfirmed` runtime에서 typed abandon projection을 준비하고 transaction을 one-shot consume한 뒤
  `abandoned_to_inventory`를 게시하며, 같은 suffix에서 로컬 Term만 detach·제거하고 host runtime terminate는 0이다.
  transaction/reducer preflight 전 allocation 실패와 exact/+1 expiry는 전부 mutation 0이다. reducer 게시 뒤에는 기존
  AppSession close cleanup callback을 포함한 forward-only 정산만 허용하며 옛 graph rollback과 host terminate는 0이다. 정상
  close, moved-stale, double-click/replay, 두 번째 Window/sibling runtime 및 같은 Window의 다른 host Term 보존을
  Debug·ReleaseFast 제품 행과 source boundary로 고정해야 CR5 Window gate를 닫는다.
- CR6a-2 launch collector는 secure discovery의 개별 `lease_free | invalid_manifest | lease_unknown`을 각각
  `lifecycle | malformed | stale` unavailable inventory로 보존하고, HostPool publication에 실패한 candidate도 endpoint
  unavailable로 reconcile한다. 이 행은 dead evidence를 complete empty inventory로 세탁하지 않는지 확인한다. actual
  daemon/manifest/inventory 행은 terminal publication 전 projection→primary typed system row 순서를 검증하며, row의
  click/Enter adopt와 fresh authority revalidation은 CR6b 전까지 0이다.
- 테스트 가능 수준을 혼동하지 않는다. CR3a~CR3c의 `production-type unit`은 내부 소유권 구조만 증명하며 실제 앱 reconnect를
  사용자가 시험할 수 있다는 뜻이 아니다. CR4 real-socket E2E가 단일 host reconnect를 처음 자동 검증하는 gate이고 CR4 제품
  배선 뒤에야 단일 Window 실제 앱 수동 시험을 시작한다. CR5가 멀티윈도우·다중 runtime 일상 사용 시험 범위를 닫고, CR6
  real-AppKit/IME/clipboard/soak가 사용자에게 기능 완성을 안내할 수 있는 유일한 제품 gate다.
- CR6c actual-AppKit 행은 별도 하네스가 current daemon/manifest에 구분 가능한 runtime을 만들고, Swift 제품 앱의
  일반 launch discovery가 발행한 primary recovery row를 read-only rect probe로 찾는다. 하네스나 ABI가 adopt를 직접
  호출하면 실패다. 실제 `NSEvent.leftMouseDown` 전/후 Metal readback 두 장은 서로 달라야 하며, 전에는
  `Recovered Sessions` row, 후에는 daemon 화면 marker와 remote Term publication·row 소멸을 함께 증명한다. 앱 종료
  는 실제 Quit confirm state machine을 통과하며, 뒤 같은 runtime의 `runtime.get` 성공과 controller/observer 0을
  확인해 shared-connection EOF 뒤 no-wire client cleanup이 host를 죽이거나 lease를 남기지 않았음을 고정한다. unique host
  외 entry mutation 0, child bounded reap, artifact root confinement도 같은 gate다. 이 행은 IME/clipboard/soak 완료로
  세지 않는다.
- CR6d actual-AppKit 입력 연속성 행은 CR6c 제품 recovery click 뒤의 실제 remote Term만 대상으로 한다. recovery 전
  runtime은 historical line과 OSC 52 write를 한 번 내보내고, 새 AppKit process는 별도 OS pasteboard sentinel을 먼저
  쓴다. recovery 뒤 sentinel 불변은 historical OSC 52 AppKit 호출 0을 증명한다. view-local 2-Set Korean
  Accessibility event-post 권한을 사전 확인한 뒤 `NSTextInputContext`에 HID event tap의 물리 key-code `CGEvent`를 흘려 `setMarkedText`/`insertText`가 모두 1회 이상 발생하고 `한글`
  screen marker가 exact 1인지 확인한다. `NSPasteboard.general`의 새 한 줄은 실제 Cmd+V `NSEvent`와 기존 paste action을
  통해 PTY에 exact 1회 도달해야 한다. historical line도 exact 1을 유지한다. probe는 action/input authority를 노출하지
  않는다. 권한이 없으면 input-source mutation 전에 `accessibility-unavailable` RED다. opt-in smoke는 original/한국어 2벌식 system-global input source ID를 전환 전에 atomic record로 봉인하고 실제
  전환 뒤에만 합성 key를 보낸다. 정상·RED·종료 복원과 앱 강제 종료 뒤 parent restore helper를 각각 검증하며, current가
  selected와 다른 제3 source이면 사용자 선택을 덮지 않고 실패해야 한다. current exact original, record 소멸, view-local
  source/marked text 복원, actual Quit confirm, runtime 생존, controller/observer 0과 exact artifact/child cleanup을 함께
  검증한다. stalled socket/backoff·soak·성능은 CR6e다.
  이 gate는 잠금 해제된 interactive WindowServer에서 Maru가 실제 frontmost여야 하며, summary의
  `session_host_input_smoke_app_active`·`session_host_input_smoke_first_responder`·`session_host_input_smoke_frontmost_pid`가
  focus 선행조건과 그 뒤의 Accessibility 판정을 분리한다. `frontmost_pid`가 `loginwindow`인 실행은 실제 HID/IME
  증거가 아니므로 성공으로 세지 않는다.
- CR6e-a1 transport baseline 행은 자동 reconnect 설정을 배선하지 않은 채 제품 deadline-aware exact-host issuer에 harness-owned 실제
  Unix stalled peer를 붙인다. accept+hello read 뒤 reply 보류와 transient connect backoff 각각에서 하나의 monotonic absolute
  deadline, typed failure, attempt/wait 및 timeout 뒤 추가 작업 0, peer/fd/RSS raw sample을 strict-schema artifact로 남긴다.
  transient backoff는 retry limit 선소진의 `host_gone + attempt=10/wait=9/end<=deadline`과 deadline 선소진의
  `deadline_exceeded + attempt=N/wait=N/end>=deadline (1<=N<10)`만 허용해 runner scheduling 차이를 계약 위반과 구분한다.
  write-only observation API의 harness 밖 제품 caller는 0이다. CR6e-a2 recovery baseline 행은 반복 CR6c actual-AppKit의
  일반 discovery→row→실제 click→remote-visible→Quit confirm timestamp와 매 iteration runtime 생존/controller·observer 0,
  앱이 되돌려 준 exact iteration identity·iteration별 고유 before/after 캡처와 final child/fd/artifact 0을 별도 strict-schema artifact로 기록한다. CR6e-a1/a2는 숫자 상한이나 장시간 완료를 주장하지
  않는다. CR6e-b는 같은 runner의 반복 baseline으로 `performance-budget.md`에 환경·표본·RSS/FD/CPU/latency hard
  cap을 먼저 확정하고, 계약된 long soak에서 deadline 초과·과잉 backoff·marker duplicate·authority/fd/process leak 0과 모든
  성능 cap을 자동 판정한다. environment mismatch는 skip/pass가 아니라 typed failure다. CR6e-b는 구현·통과했고, 후속
  CR6e-c가 자동 reconnect 제품 배선을 소유한다. c1은 app-global bounded host job/completion과 stale/duplicate/cancel
  정산, c2는 thread/queue 비소유 worker entrypoint의 exact-host connect/hello, absolute deadline 보존, typed failure와
  move-only `Client` completion exact-once 정리, c3a는 128-bit incident identity와 pool/connection generation·모든 bound
  admission·absolute deadline을 재검증한 비차단 CR5 job adoption, c3b1은 final-address physical worker와 cancellation
  wake/join, c3b2a는 admission-loss 없는 reversible c1 예약·최초 identity 보존 coalesce·한 frame당 completion/admission/dispatch
  각 최대 하나, c3b2b/c3c는 frame-thread block 0·bound admission 제품 정산·main-owner CR5 publication 및
  actual AppKit socket 단절 뒤 같은 host/runtime/child PID·output/input/copy/resize·서로 다른 sibling runtime의
  단절 전후 live/controller 보존과 모든 worker/fd/client/admission final 0을 검증한다.
  **CR6e-c1~c3c 구현·제품 actual-AppKit 검증 완료.** strict `maru.session-host-cr6e-c3c-appkit.v1` validator는
  unknown/duplicate/missing field를 거부하고 identity·continuity·sibling authority·blocking operation 0·cleanup을 판정한다.
  AppSession의 terminal core mutation은 `enqueueCoreCommandForTerm` 또는 `enqueueCoreCommandForSurface`에서 exact Term backend를
  선택하며, scroll/focus/mouse/selection/find/config/reset이 host-backed placeholder core로 새는 제품 경로는 source boundary 0이다.
  direct in-process enqueue는 같은 helper의 active local O(1) fallback 하나만 허용한다.
- **CR6f output-wake: 구현.** `PtyEventQueue`의 성공 publication만 notifier를 부르고 QueueFull/QueueClosed는 wake를 만들지
  않는지, callback이 queue mutex 밖에서 실행되는지 고정한다. daemon/restore는 runtime 생성 전에 process-local nonblocking
  CLOEXEC self-pipe를 만들고, reader는 write end에 byte만 coalesce하며 `poll_owner.Owner`만 read end와 runtime event queue를
  drain한다. wake가 도착한 owner turn은 cadence deadline을 기다리지 않고 모든 eligible client의 기존 producer sweep을
  시작하되, 이미 진행 중인 sweep을 reset하지 않는다. pipe 포화·EINTR·spurious wake·broken read end, upgrade restore의
  notifier/fd 재구성, idle CPU와 fd/child cleanup을 unit/process gate로 검증한다. 실제 forkpty `/bin/cat`의 구분 가능한 input을
  controller wire로 보내 healthy client의 exact delta marker까지 측정한 raw artifact와 `performance-budget.md` hard cap이 없으면
  구조 배선만으로 CR6f 완료 또는 default-on 가능을 주장하지 않는다. 현재 제품 gate는 1초 idle wake delta 0과 CPU
  cap, actual 1·10·100 runtime screen projector exact-zero, 7 active marker의 notifier/write/drain 증가를 소유하며,
  장시간 idle soak는 운영 백로그로 남긴다. E3b metadata visit 제거는 별도 E3b 제품·artifact gate에서 구현·검증됐다.
- **K1 cwd authority model/wire: 구현, 제품 kernel cwd parity 미완.** MRSH v2 metadata의 optional `cwd_host`는
  부재를 legacy unknown authority로 정규화하며, non-empty authority는 non-empty cwd와 같은 observation transaction에서만
  소유·교체한다. type/duplicate/authority-without-cwd는 fail-close하고 server·wire·owning DTO·prepared reducer·GUI projection의
  digest/equality/allocation rollback에 함께 결속했다. K1 단계에서는 producer가 의도적으로 empty authority만 게시해 제품
  동작을 바꾸지 않았고, 현재 producer 상태는 아래 K2 행이 소유한다. `test-session-host-kernel-cwd-k1`이 Debug·ReleaseFast
  wire와 source/status boundary를 검증한다. 이 K1 gate 자체는 500ms kernel sampler나 실제 daemon의
  shell-integration 없는 bash/sh·detach/reattach parity의
  완료 증거가 아니며, 각각 아래 K2 상태와 후속 K3 제품 gate를 본다.
- **K2 host-side kernel cwd sampler: 구현, K3 제품 parity 미완.** `RuntimeManager`가 runtime별 fixed
  `PATH_MAX` cwd와 `HOST_NAME_MAX` authority cache를 소유하고 OSC 7 cwd가 비며 SSH destination이 없을 때만
  core lock 밖에서 `PtySession.processCwd`와 fresh `gethostname`을 최대 2 Hz 호출한다. 실패·비 UTF-8·비절대 경로,
  OSC/SSH 우선 전환, runtime 종료·restore rollback은 cached pair를 비우거나 제거한다. paired cache generation은
  `runtime_metadata_sampler.Source`와 canonical observation cache generation에 함께 들어가 core generation이 그대로여도
  client metadata token과 JSON이 갱신된다. deadline 전 source preflight는 core lock 없이 generation만 읽고, 실제
  materialization은 eligibility를 강제 재확인하되 기존 eligible cache의 syscall refresh는 500ms metadata cadence에
  남겨 output wake를 막지 않는다. 외부 attach preflight는 non-empty `cwd_host` backing bytes를 exact charge하고,
  metadata+screen mixed delta에서는 aggregate-bound `screen_staging`을 검증한 뒤 moved payload range를 ledger 한 곳만
  소유하게 해 정상 update를 invariant failure로 닫지 않는다. `test-session-host-kernel-cwd-k2`가 Debug·ReleaseFast에서 fixed cache,
  checked generation, 500ms throttle, local fallback, OSC authority 우선, SSH 억제, token/materialization, lifecycle과
  exact metadata footprint 및 source boundary를 검증하고, 기존 P5c3d built-product E2E가 mixed delta 뒤
  controller/observer 입력·reattach·`--stream` 지속을 검증한다. 실제 독립 daemon·detach/reattach·sibling·frozen N-1
  소비자 parity는 K3 완료 증거가 필요하다.
- **K3 actual daemon kernel cwd parity: 구현.** 별도 실제 daemon, generation-backed `HostAdapter`,
  `shell_integration = null`인 `/bin/sh` runtime 두 개를 쓰는 Debug·ReleaseFast 제품 gate가 current client의 paired
  kernel cwd/hostname, A detach 중 cwd 변경 뒤 pump 없는 initial reattach, B sibling observation 불변, 실제 PTY
  echo로 들어온 local/remote OSC 7 우선과 known SSH destination 억제를 한 흐름에서 검증한다. K2
  lifecycle/handle-reuse와 K1 frozen N-1 absence, `cwd_axis`의 `termCwd`/`termCwdForDisplay` 단일 소비자 축도 같은
  K3 completion step의 선행 증거이며, 어느 것도 실제 daemon gate를 대신하지 않는다.
- **P4 input parity micro-gate: 구현.** `test-session-host-input-parity`가 Debug·ReleaseFast에서 host-backed
  AppSession의 DECSET 1003 exact-mode/중복·modifier·chrome 억제, 실제 forkpty host reader의 xterm SGR no-button motion
  byte, `selection_scroll_and_extend` 두 번 뒤 authoritative copy와 source boundary를 exact-count한다. AppSession 행은
  reader 없는 product fallback의 실제 SGR bytes로 같은 셀 중복, 1000/1002 mode, Shift/Option override와 chrome 경유 재진입을
  함께 고정하고, host 행은 독립 forkpty child가 받은 bytes와 viewport 밖 authoritative selection text를 검증한다.
  capability 없는 구 host의 motion 0·selection transaction no-op은 동적 legacy process E2E가 아니라 source boundary다.
- **P4 E2 runtime-shared observation cache: 구현(E2a·E2b·E2c artifact/cap gate).** E1은 위 `CR6f output-wake`와 같은 순서 항목이다.
  E2a의 `runtime_observation_cache.Cache`는 canonical bytes와 checked-monotonic change token을 소유하고, 동일 bytes의
  allocation/token 증가 0, changed prepare→exact-token commit, stale prepared 거부, OOM·token overflow 때 이전 bytes/token
  무변경과 explicit discard, unpublished/published-empty 구분, caller-owned byte cap의 allocation 전 거부를 Debug·ReleaseFast로
  고정한다. cache-owned allocator와 final-address owner binding은 cross-cache commit 및 allocator-mismatch free를 막는다.
  outstanding prepared count는 commit/discard에서만 exact once 감소하고 nonzero deinit은 상태를 보존한 채 거부한다.
  E2b는 heap-pinned runtime별 cache owner, same cadence epoch materialization 1회, attach current cache와 user-action fresh
  barrier, canonical JSON raw embedding, subscription별 token/revision queue-admission commit을 제품 경로에 연결한다. runtime
  terminate는 cache를 exact once 회수하고 same-PID upgrade는 파생 cache를 명시 재구성한다. subscription은 canonical bytes를
  복제하지 않아 slow/OOM client의 delivery 상태가 cache와 sibling을 소유하지 않는다. E2c source gate는 lock-free core
  generation과 cache 생성 뒤 steady-state allocation-free foreground identity 비교로 idle cadence materialization을 0으로 만들고, 실제 `/bin/cat`
  runtime 1·10·100개에서 consumer 2회·idle next epoch가 runtime당 최초 1회만 materialize하며 runtime 하나 변경 뒤 정확히
  1회만 증가함을 ReleaseFast로 고정한다. private probe v3를 쓰는 controller+slow observer macOS raw artifact는
  누적 materialization·core-lock 획득/hold와 1초 idle 전후 증분을 기록한다. exact-schema validator는 lock 획득
  `materializations * 3`, idle materialization/lock/allocation opportunity 0, 개별 lock hold 25ms와 기존 idle CPU 25ms,
  healthy latency median 10ms/tail 20ms, raw-sample RSS analytic cap을 함께 판정한다. E2 완료는 P4 전체 완료를 뜻하지 않는다.
- termination revoke는 writer offset 0 purge와 모든 partial offset의 connection abort를 검증하며, 이미 전송된 prefix 외
  payload suffix와 후속 sibling frame은 0이다.
- mutation `beginMutation`과 freeze/seal의 두 interleaving, Window 이동 중 X partial 뒤 Y/input/control/paste/IME suffix
  전부 quarantine, takeover 송신 0만 old writable 복귀, unknown/conflict의 old write 0을 검증한다. 입력은 0/partial/full wire
  admission에서 duplicate 0, 자동 재전송 0, incident·runtime notice 1을, paste는 1 MiB/item·runtime 1개·app 8 MiB·10분 TTL,
  zeroize, Discard/전체 재전송 single-use 확인과 suffix-only action 0을 검증한다. BEL·OSC 9/777·OSC 52는
  reconnect 전 historical replay와 실제 AppKit clipboard 호출 0을 검증한다. X ambiguous frame 뒤 Y/control suffix 전부 폐기,
  mutation freeze 중 old/new wire mutation 0, snapshot+delta contiguous catch-up도 자동 gate다. 실제 AppKit render/IME와
  장시간 poison/backoff는 CR6 제품 gate다.
- CR4b 단일-runtime 제품 gate는 CR4a `HostReconnectJob`의 exact staged receipt에서만 시작한다. CR4a placeholder
  publication은 mutation owner의 old generation을 전진시키지 않아 새 input과 queue pump를 모두 거부하되 기존 queue는
  mutation 0으로 보존한다. stable queue seal 전
  `controller.status`/`controller.takeover` wire는 0이고, active mutation lease가 있으면 owner turn은 waiting만 남긴다.
  clean seal은 key/control/IME 원문을 zeroize하고 metadata만 보존하며, 완전한 원문을 별도 소유한 paste만 bounded
  quarantine한다. 실제 socket 성공은 status 1·takeover 1, 동일 absolute deadline과
  `new_controller_evidenced`를 증명한다. wire authority를 얻어도 candidate의 local attachment/cleanup binding은 CR4c
  publication 전까지 observer로 격리되어 mutation 권위가 0이며, RemoteGeneration publication·forced resize·input도 0이다. stale generation,
  foreign controller, reply-loss-after-prefix는 각각 `authority_conflict | takeover_sent_unknown`으로 exact 한 번 봉인하고
  status 재조회로 성공을 추정하거나 old writable을 복원하지 않는다. pre-send OOM/deadline도 CR4a가 이미 게시한
  unavailable node/generation을 유지하며 candidate/receipt/queue/paste/registry/pin ledger가 유한하게 정산되는지 확인한다.
  allocator callback 재진입은 첫 wire/할당 전 one-shot committing owner에서 거부되어 status/takeover가 exact 1이고,
  exact `resource_exhausted | invalid_request | internal` 응답은 authority conflict로 세탁하지 않고 pre-takeover failure와
  Client fail-close로 수렴한다.

## PR마다 확인할 질문

- 새 기능이 이 표의 어느 검증 경로에 연결되는가?
- 자동 검증이 불가능하다면 어떤 수동 검증 산출물을 남기는가?
- 새 산출물이 기존 snapshot, trace, replay, future inspector와 같은 도메인 데이터를 쓰는가?
- 새 코드가 `project-structure.md`의 facade/책임 폴더 규칙과 `layering-and-portability.md`의 L2/L4 경계를 지키는가? `main.zig`, Swift, `app_session.zig`에 새 정책·순수 로직을 넣지 않았는가?
- hot path, queue, lock, allocation/copy, thread hop, I/O, frame tick에 새 부담을 만들었는가? 만들었다면 어떤 예산·stress·artifact로 확인했는가?
- 한계가 새로 드러났다면 PR 설명과 사용자 보고에 적었는가?

### 영속 host 사용자 단어 구분자

- **상태: 구현.** host-backed 더블클릭은 client의 현재 `input.word-separators`를 UTF-8 경계
  64 byte 이하의 pointer-free `SelectRequest`에 복사하고 hex wire로 보낸다. host는 길이·hex·UTF-8을
  strict 검증한 뒤 권위 `TerminalCore.selectWordAt`에 전달한다.
- **자동 검증:** `test-session-host`가 fixed request/raw decode, 64-byte cap, odd/invalid hex, invalid UTF-8,
  server field routing을 검증한다. fresh-process 독립 host E2E가 `foo.bar`에 구분자 `.`를 적용해
  `foo`만 선택·복사함을 검증한다.
- **남은 gate:** additive field를 모르는 same-major 구 host는 기본 공백 경계로 degraded된다.
  frozen 구 binary 재접속 행은 아직 별도 자동 gate가 아니다.

### 영속 host 전체 선택

- **상태: 구현.** host-backed `select_all`은 빈 placeholder가 아니라 host의 권위 `TerminalCore.selectAll`을
  실행한다. client는 viewport highlight와 별도로 전체 선택 의도를 소유하고, 이후 복사는 additive `all` 모드로
  host lock 아래 `selectAll → extractSelection → clear`를 원자 실행한다.
- **자동 검증:** `test-session-host`가 typed request의 `all` discriminator fail-close, server additive field
  routing과 transient host selection clear, 실제 host의 viewport보다 긴 scrollback 전체 선택·복사를 검증한다.
- **호환 한계:** `all` op를 모르는 same-major 구 host는 `{sel:false}`를 반환해 새 client가 절대 좌표를
  추측하지 않고 현재 viewport 선택으로만 degraded된다. frozen 구 binary 재접속 행은 별도 자동 gate가 아니다.

### P4 N1 bounded notification journal

- **상태: 구현(독립 pure owner).** final-address host owner가 `{host_id,runtime_id,event_id}` stable identity,
  GUI/OS delivery bit, checked-monotonic ID와 bounded owned payload를 소유한다.
- **자동 검증:** `zig build test-session-host-notification-journal`이 Debug·ReleaseFast runtime 8개와 boundary 1개로
  cap, prepare-before-evict, allocator fail-index rollback, copied owner 거부와 N2a의 단일 `RuntimeManager` 제품 owner를 검증한다.
- **미완료 경계:** daemon-internal macOS sink, runtime label/config 배선은 N2b이고 cold-launch route는
  N3다. 따라서 N1만으로 GUI 0 배너나 background notification 제품 완료를 주장하지 않는다.

### P4 N2 notification admission·delivery

- **상태: N2a·N2b1·N2b2·N2b3 자동 구현 완료, 실제 Notification Center 제품 gate 미완료.** N1 journal은 `RuntimeManager` final owner, 실제 OSC core slot, GUI
  `runtime.notification` consume과 same-PID outer optional handoff에 연결됐다. N2b1의 product config/label metadata,
  controller-bound `config.update`, stable-key GUI wire가 연결됐다. 실제 daemon/socket/PTY gate는 live on/off와 label 변경,
  detach→재attach 뒤 현재 config와 runtime-ID fallback 재설치, capability-aware typed HostAdapter의 exact
  `delivery_version:1` selector를 Debug·ReleaseFast에서 검증한다. partial multi-runtime 전파/보상 실패는 미적용 entry로
  남겨 frame binding 완전본이 재시도한다. daemon-internal macOS sink는 N2b2에서 fresh/restore daemon owner에 연결됐고,
  N2b3의 GUI history/OS stable-key 투영도 연결됐으며 Swift type-check와 실제 `Maru.app` 링크까지 통과한다.
- **N2a 자동 검증:** `zig build test-session-host-notification-admission`이 Debug·ReleaseFast에서 generation-CAS
  admission의 OOM/rejection rollback, 일반 OSC 2 KiB overflow one-shot 계수와 runtime 공정성, UTF-8/control-sequence
  sanitizer와 normalized cap, GUI/OS delivery bit 독립, handoff row/ID/bit/counter 보존, allocation fail-index 및
  corrupt/foreign/cap 초과 fail-close를 검증한다.
- **N2b 필수 자동 검증:** N2b1은 초기 fail-closed snapshot, config off·발화 시점 label snapshot,
  controller-generation/config-generation 2축, observer·legacy·미지 필드·stale·cross-runtime mutation 0,
  capability별 exact stable-key/legacy GUI schema와 response-admission 뒤 `.gui` ack를 검증한다. N2b2는 daemon-internal
  adapter의 typed `{hid,rid,eid}`, accepted 뒤 `.os` ack, permission/bundle/entitlement degraded terminal, 같은 row의
  250ms→최대 8초·6회 bounded retry와 sibling 공정성, async sibling의 exact secondary ownership, journal 축출 뒤에도
  저장한 전체 route로 exact request expire, 10초 callback timeout 뒤 process-local slot 회수와 fresh request 가능성을 검증한다. N2b3는 host-backed GUI history가
  owned `{hid,rid,eid}`와 host occurrence timestamp/display-label snapshot을 보존하고, ABI가 route 유무와 scalar를 분리해
  Swift의 daemon 동형 canonical identifier 및 `hid`/`rid`/`eid` userInfo로 투영하며, route 없는 알림은 기존 UUID/local
  click route를 유지하고 GUI가 `.os` bit를 내리지 않음을 Debug·ReleaseFast에서 검증한다.
- **제품 gate:** 실제 host-backed runtime의 OSC 9/777이 GUI 연결 중 stable key로 기존 인앱/배너 경로에 한 번만 나타나고,
  GUI 0에서는 signed bundle daemon adapter가 `hid`/`rid`/`eid`를 가진 배너를 게시한다. provisioned runner가 없는 실제
  Notification Center 행은 fixture로 대체해 완료 처리하지 않으며 N3 cold-click exact attach와도 구분한다.

### P4 N3 notification cold-launch route

- **상태: 자동 구현·검증 완료, 실제 OS gate 미완료.** stable response는 exact lowercase `hid`/`rid`, nonzero integer
  `eid`, shared formatter와 동일한 request identifier를 모두 검증하며, stable route가 있으면 process-local
  `wt`/`sid`를 사용하지 않는다. callback queue를 main으로 가정하지 않고 값 타입 파싱 뒤 `MainActor`로 명시적으로
  hop한다.
- **필수 자동 검증:** delegate pre-run 설치, launch 전 bounded exact-key queue와 one-shot drain, malformed/incoherent route
  거부, live binding의 app-wide probe와 cross-Window duplicate mutation-zero 거부, exact runtime의 중복 attach 없는
  활성화, binding이 없을 때 current projection의 exact 한 행 또는 projection/config-off 상태의 secure registry exact
  membership만 fresh authority 검증 뒤 adopt, stale/unknown/duplicate/attach 실패의 spawn·topology mutation 0을 Debug·ReleaseFast와 실제
  AppHost ABI/Swift type-check로 검증한다.
- **남은 OS gate:** provisioned signed runner에서 GUI 0 OSC 발화→실제 배너 클릭→cold launch와 GUI-live 발화→Quit→기존
  배너 클릭이 모두 원래 `host_id:runtime_id` 및 child PID 불변으로 attach하는 구조화 artifact가 필요하다. synthetic
  `UNNotificationResponse`나 source fixture는 이 Notification Center gate를 대체하지 않는다.

### Session default G1 config provenance

- **상태: 구현, G2 정책에서 소비 중.** resolved `session.keep-alive-after-quit` bool과 별도로 마지막 적용 가능한
  syntactic occurrence를 `absent | explicit_valid(value) | explicit_invalid`로 보존한다. bool 유효성은 schema parser가
  단일 소유하며 provenance 전용 parser를 두지 않는다. invalid occurrence는 직전 resolved bool을 유지한 채 provenance만
  `explicit_invalid`로 바꾼다. 현재 OS suffix와 generic은 같은 파일 순서를 따르고 외국 OS
  occurrence는 provenance에 영향을 주지 않는다.
- **자동 검증:** `zig build test-session-host-config-provenance`가 Debug·ReleaseFast에서 config aggregate의 미설정,
  valid→invalid, invalid→valid, generic/current-OS 양방향 순서와 foreign-OS
  무관성을 검증한다. 실제 파일 경계는 missing/readable/directory-unreadable/정확히 1 MiB readable/1 MiB+1 oversize를
  검증한다. G1은 기존 `default=false`와 forgiving load 동작을 유지하며 파일 write·notice·bootstrap을 실행하지 않는다.
- G1의 parser/file fixture를 G2의 실제 bootstrap·Reset 성공/실패·경합 증거로 대체해 해석하지 않는다.

### Session default G2 explicit override retention

- **상태: 구현, focused/product gate green.** L0 lease 뒤 AppKit/첫 AppSession 전 app-global owner가 G1의 resolved bool과 두
  provenance를 exact once scalar snapshot으로 만들고 모든 Window가 공유한다. release A default `false`와 absent profile은
  그대로이며 G2 bootstrap은 파일 write/notice 0이다.
- **Reset gate:** whole Reset은 `absent`에는 keep-alive 줄을 만들지 않고 `explicit_valid`/`explicit_invalid`에는 Reset 전
  live bool을 기본값과 같아도 canonical explicit override로 atomic replace한다. row Reset/Backspace는 값·snapshot·dirty/remove
  queue·파일 mutation 0이고 전용 수동 변경 notice만 낸다. write 실패는 부분 파일 0이다.
- **자동 검증:** `zig build test-session-host-config-override-retention`이 Debug·ReleaseFast에서 absent/valid/invalid,
  exact-one/duplicate owner, multi-Window snapshot, toggle/reload 교체, row no-op, 실제 atomic replace 실패와 source boundary를
  검증한다. `mise run macos-app-instance-lease-smoke`는 실제 fresh 앱 process에서
  `lease → G2 bootstrap → duplicate reject → AppKit/AppSession`과 loser의 bootstrap 전 exit/config·workspace·cache mutation 0,
  `SIGKILL` 뒤 successor 재획득/bootstrap을 검증한다. G1 parser fixture나 in-process owner 단위만으로 제품 순서를 완료
  처리하지 않는다.
- **범위 밖:** absent explicit `true` materialization, persistent retry notice, default `true` 전환과 frozen A rollback은 G3 백로그다.

### Session default G3 frozen-release migration

- **상태: 별도 release 백로그, P1~P5 완료 조건 밖.** 현재 제품은 `default=false` opt-in을 유지한다. 사용자가 default-on을
  다시 승인하기 전에는 아래 trust 결정이나 제품 config 구현을 시작하지 않으며, component 선결조건의 기존 자동 gate만 보존한다.
- **확정한 trust 결속:** environment 설정 REST나 deployment의 `sha/ref/environment`만으로 protection 통과를 주장하지 않는다.
  attempt-scoped jobs의 exact current `run_id/run_attempt/job` URL과 deployment status의 같은 job URL을 결속하고,
  관리자 bypass 불가, 공식 `pending` 이력과 exact-one `in_progress`를 environment의 recognized protection rule과 함께 요구한다.
  REST가 보장하지 않는 배열 순서나 비공식 `waiting` 상태는 권위로 사용하지 않는다.
  component resolver만으로는 transport·pagination·현재 실행 executable·workflow 배선을 증명하지 않으므로 이 네 권위까지
  실제 adapter가 결속하기 전에는 `protected_environment=true`를 만들지 않는다.
- **선결조건 상태: 부분 구현, 외부 gate 미준비.** G3 제품 config 코드는 provisioned `Session host product / default-on` runner와 immutable
  release A manifest가 모두 준비된 뒤에만 시작한다. `build.zig.zon` version SSOT는 generated macOS plist와 tag gate까지
  연결됐다. OS 중립 `release_manifest.zig`는 canonical A/B JSON, bounded parser/writer와 intrinsic repository/release/source/
  build/compatibility/signing/asset/evidence/predecessor 정책을 단일 소유한다. 같은 모듈의 typed observation policy는 실제
  manifest/A predecessor canonical bytes의 SHA, GitHub identity, executable compatibility/signing, regular no-follow asset,
  artifact/release attestation, DMG 내부 executable과 evidence candidate를 fail-close로 교차검증한다. compatibility/signing
  관측은 frozen executable SHA에, schema/result 관측은 evidence summary SHA에 각각 결속하며
  release publication typed policy는 trusted tag/protected environment, pinned Action, no-clobber, immutable B predecessor,
  manifest exact-one+열거 asset exact-set과 attestation→draft→evidence→manifest→재다운로드→publish→release attestation
  exact 순서를 fail-close한다. `test-session-host-release-manifest`가 이를 Debug·ReleaseFast에서 검증한다. 다만 GitHub
  API·codesign·DMG를 실행해 typed observation을 만드는 executable adapter의 선행 계약은
  `release_adapter_contract.zig`가 allocation-free `pre-publish`·`verify-predecessor` command, 두 phase에서 caller가 absent leaf로
  지정해야 하는 canonical absolute `--work-dir`의 경로·alias 계약(root·`.`/`..` component·중복/후행 slash 및 모든 pathname의
  exact·component-boundary ancestor/descendant 관계 거부)과 phase별 exact option,
  canonical manifest asset 이름, repository/tag, `release` protected environment와 summary schema를 닫고 observation JSON 입력을
  금지하며 `test-session-host-release-adapter-contract`가 Debug·ReleaseFast에서 검증한다. macOS 파일 권위 leaf는 모든 absolute
  path component와 final을 `openat(O_NOFOLLOW)`로 열어 regular/bounded bytes·SHA-256·device/inode를 같은 fd에서 만들고 input
  hardlink alias를 거부한다. summary owned publication은 0600 `O_RDWR` temp의 complete write·fsync 뒤 같은 fd에서 size/SHA를 만들고
  `RENAME_EXCL`+parent fsync+final inode 재검증 뒤 held file/parent fd를 move-only owner로 반환한다. 기존 void
  publication은 owner를 닫아 durable output만 남기는 wrapper다. work-dir도 absent leaf에만 0700으로 만든다.
  `test-session-host-release-adapter-files`가 이를 Debug·ReleaseFast 실제 filesystem에서
  검증한다. pre-publish workspace owner는 caller-owned absolute absent root를 0700으로 만들고 held parent/root identity에서 closed typed
  child pathname만 유도한다. pre-publish namespace는 exact `current-manifest`·`predecessor-manifest`·`predecessor-assets`·`dmg`·`current-assets`,
  baseline runner namespace는 exact `default-false`·`signed-app-quit`·두 JSON leaf·aggregate이며, unexpected entry나
  replacement를 허용하지 않고 초기화/empty root cleanup 실패 시 durable removal까지 retry
  권위를 보존한다. `test-session-host-release-adapter-pre-publish-workspace`가 이를 Debug·ReleaseFast actual filesystem에서 검증한다.
  pre-publish phase transaction은 validated token 뒤 failure-pristine deadline, workspace와 모든 current/predecessor leaf를 닫힌 순서로 호출하고,
  deadline start 이후 fail-index마다 실패하면서 retry 권위를 남긴 attempted private owner까지 역순 정리하며 cleanup이 전부 성공한 뒤에만 summary를
  게시한다. observation setup 실패와 private cleanup 실패에도 observation을 terminal cleanup하고, cleanup 실패 시 publication 0과
  retry authority를 보존하며 private cleanup 뒤 live deadline 최종 검증·deadline cleanup·성공 publication·observation 해제 순서는
  `test-session-host-release-adapter-pre-publish-phase`가 Debug·ReleaseFast에서 검증한다. production adapter 타입 배선과 frozen U5
  E2E는 이 transaction gate의 범위 밖이다.
  verify-predecessor phase transaction은 failure-pristine deadline 뒤 published role-A manifest와 immutable asset owner에서 summary bytes를 먼저 준비하되 output을
  열지 않고, 모든 private owner와 workspace cleanup, live deadline 최종 검증과 deadline cleanup이 성공한 뒤에만 exact-one publish한다. 실패하면서 retry 권위를 남긴
  attempted owner를 포함한 단계별 reverse cleanup,
  cleanup failure와 final deadline 만료의 publication 0, retry authority, deadline과 prepared bytes exact release는
  `test-session-host-release-adapter-verify-predecessor-phase`가 Debug·ReleaseFast에서 검증한다. leaf 의미, production executable과
  workflow/U5 E2E는 이 gate의 범위 밖이다.
  production verify-predecessor `Execution`은 bootstrap의 exact command/context/pinned CLI, validated token과 disjoint supplied buffers를
  transaction의 candidate single-read, private manifest materialization, published-A attestation, immutable assets와 prepared summary
  publication에 연결하고 private cleanup 뒤 owned live deadline을 최종 검증한다. result/bootstrap/token/context/command/buffer alias를 side effect 전에 거부하고 invalid/copied/pre-owned owner side effect 0, foreign/expired deadline publication 0, 성공/ordinary failure empty state, cleanup failure retry authority와
  sensitive borrow scrubbing은 `test-session-host-release-adapter-verify-predecessor-product`가 Debug·ReleaseFast에서 검증한다. 실제 GitHub
  success와 workflow/U5 E2E는 별도 증거다.
  release validator executable은 bootstrap과 exact GH_TOKEN 뒤 closed command union으로 두 production `Execution` 중 하나만 호출한다.
  20분 compile-time phase budget과 component 상한별 disjoint fixed storage, phase 교환/fallback 0, failure 전파 및 production type compile은
  `test-session-host-release-validator-executable`이 Debug·ReleaseFast에서 검증한다. 실제 child 성공, 최소 25분 workflow timeout과
  publish ordering은 release workflow/U5 gate가 별도로 증명한다.
  production `Execution`은 bootstrap의 pre-publish command/context/pinned CLI와 validated token만 받아 shared deadline/workspace 및
  기존 production `...Until` leaf를 transaction에 연결하고 private cleanup 뒤 `Execution` 자체가 소유한 live deadline만 최종 검증한다. foreign/expired deadline은 publication 0이며 ordinary failure는 empty state로 돌아가고 cleanup 실패만 caller-owned
  execution에 retry authority를 남기며 result/bootstrap/token/context/command/buffer/Apple storage alias를 side effect 전에 거부하는 계약은 `test-session-host-release-adapter-pre-publish-product`가 Debug·ReleaseFast에서
  검증한다. 실제 GitHub/Apple 성공은 release workflow와 frozen U5 E2E가 별도로 증명한다.
  release adapter가 사용할 macOS 외부 명령 leaf는 `bounded_process.zig` 한 곳에서 absolute exec, stdin `/dev/null`,
  merged output exact cap, exit 0+EOF, monotonic timeout과 process-group kill/direct-child reap을 소유하고 기존 upgrade codesign이 먼저
  재사용하며, `test-session-host-bounded-process`가 Debug·ReleaseFast 실제 process로 검증한다. 그러나 release adapter executable
  배선 전에 `release_adapter_environment.zig`가 실행 프로세스에서 parser 소유의 exact 11개 이름만 직접 조회하고,
  OS 중립 `release_adapter_context.zig`가 해당 `GITHUB_*` identity key의 bounded·canonical 파싱과 trusted
  protected tag push/workflow 조합, manifest repository/release tag/source commit/build 결속을 닫으며
  `test-session-host-release-adapter-environment`와 `test-session-host-release-adapter-context`가 Debug·ReleaseFast에서 검증한다.
  이는 caller가 identity 문자열을 임의 조립하는
  경로를 닫는 component seam일 뿐 프로세스 환경 자체를 GitHub service 증거로 승격하지 않는다. OS 중립
  `release_adapter_github_json.zig`는 `max_response_bytes`가 소유하는 64 KiB 이하의 완전한 GitHub REST JSON root 하나와
  manifest scalar cap을 공통 envelope로 고정한다. `release_adapter_github_repository.zig`는 그 envelope의 repository 응답
  하나에서 additive field는 허용하되 exact `id`·`name`·`full_name`·`owner.login`의 missing·duplicate·wrong wire type,
  zero/foreign/internal mismatch와 context ID·owner/name
  불일치를 fail-close하며 `test-session-host-release-adapter-github-repository`가 Debug·ReleaseFast 및 allocation fail-index로 검증한다.
  이는 이미 캡처된 bytes의 component 의미 검증이며 GitHub transport나 `gh` executable 권위는 증명하지 않는다.
  `release_adapter_github_release.zig`는 같은 envelope에서 release REST 응답의 exact nonzero numeric ID, canonical tag와 boolean
  `draft`·`prerelease`·`immutable`을 duplicate·wrong wire type까지 닫는다. tag-name endpoint는 published release 전용이므로
  current draft는 authenticated paginated release 목록 전체에서 exact ID+tag match를 하나만 찾고 order/latest/page truncation을
  권위로 쓰지 않는다. draft는 collection parser 전용이고 scalar parser는 published immutable predecessor만 받는다. draft 후보는
  `draft=true`·`prerelease=false`와 absent/false immutable만, published predecessor는 `false/false/true`만 허용하며 predecessor
  응답이 `immutable`을 생략해도 불변성을 추정하지 않는다.
  `test-session-host-release-adapter-github-release`가 두 상태, additive field, cap, malformed/missing/type/duplicate/trailing,
  zero/foreign/noncanonical identity, 상태 혼용과 allocation fail-index를 Debug·ReleaseFast에서 검증한다. `target_commitish`를 source
  권위로 쓰지 않는다. `release_adapter_github_git.zig`는 exact tag ref와 annotated-tag object의 각 한 hop을 lowercase 40-hex
  self/target SHA 및 closed `commit|tag` kind로 파싱한다. 첫 annotated hop은 release tag name도 결속하고 후속 nested hop은 서로 다른
  non-empty bounded name을 허용해 SHA 체인을 막지 않는다. `test-session-host-release-adapter-github-git`가 lightweight ref, annotated/nested
  target, cap, malformed/missing/type/duplicate/trailing, foreign/noncanonical identity와 두 allocation path의 fail-index를
  Debug·ReleaseFast에서 검증한다. `release_adapter_git_resolver.zig`는 final-address `Backing`이 소유한 caller-sized `[]Sha` 길이를 정책 상한으로 받아 0-hop
  direct commit과 nested chain의 exact manifest commit 수렴, self/earlier cycle, depth exhaustion, foreign current/commit,
  replay·copied resolver/backing·cross-resolver reuse·owner/backing overlap·결속 뒤 descriptor drift를 terminal fail-close한다. `test-session-host-release-adapter-git-resolver`가 이를
  Debug·ReleaseFast에서 검증한다. 제품 최대 깊이 선택과 API 호출은 아직 없다. 이 역시 component 의미 검증이다.
  environment 응답은 `release_adapter_github_environment.zig`가 exact nonzero `release` identity, 관리자 bypass 불가, rule ID/type와 rule별
  effective payload를 typed fact로 보존한다. wait timer는 1~43,200분, reviewer는 1~6개의 exact `User|Team`+nonzero ID,
  branch policy는 rule/object 동시 존재와 두 mode exact-one을 요구한다. unknown future rule은 파싱 호환성을 위해 보존하되
  보호 증거로 세지 않는다. `test-session-host-release-adapter-github-environment`가 malformed/missing/type/duplicate/trailing,
  foreign/zero identity, duplicate/incoherent/empty policy와 allocation fail-index를 Debug·ReleaseFast에서 검증한다. 이 parser는
  configured environment component만 증명하며 current workflow run/job이 그 protection을 통과했다는 증거는 아니다.
  `release_adapter_github_deployment.zig`는 attempt-scoped jobs, source/tag/environment로 좁힌 deployments와 각 status 전체 이력을
  함께 해석해 exact release signing job과 공식 `pending` 및 exact-one `in_progress`를 가진 deployment 하나만 environment observation에
  결속한다. malformed URL·foreign repository/app·stale/완료 job·누락/중복 backing·0개/복수 match를 fail-close하며
  `test-session-host-release-adapter-github-deployment`가 Debug·ReleaseFast와 allocation fail-index에서 검증한다. 이 resolver도
  이미 획득한 component bytes의 의미만 증명하며 transport·pagination·workflow 배선을 대신하지 않는다.
  `release_adapter_github_transport.zig`는 caller 문자열 URL 대신 closed request enum에서 exact GET endpoint/header를 만들고,
  collection에 `per_page=100`과 `--paginate --slurp`를 함께 강제한 뒤 bounded outer page를 endpoint shape에 맞게 직접 flatten한다.
  macOS leaf는 absolute executable과 fixed argv만 공용 bounded process에 넘기고, child 환경을 exact `GH_TOKEN`과
  `GH_PROMPT_DISABLED=1`로 교체하며 stderr를 protocol bytes에서 제외한다. token·endpoint identity·complete JSON/scalar/capture cap,
  pagination shape/count 불일치와 child failure/timeout은 fail-close한다. `test-session-host-release-adapter-github-transport`가
  Debug·ReleaseFast 실제 process와 injected executor에서 이를 검증한다. 이 leaf가 받는 GitHub CLI executable의 공급망 권위와
  실제 release workflow의 선택·배선은 아직 증명하지 않는다.
  `release_adapter_github_attestation.zig`는 artifact attestation에 한해 exact `gh attestation verify` argv와 clean token
  environment/bounded stdout을 소유하고, exact-one JSON result의 verified certificate summary를 trusted repository/source/tag/
  workflow/run-attempt/GitHub-hosted runner에 결속한다. SLSA v1 statement는 subject 이름/SHA exact-one과 certificate/context
  교차검증에만 쓰고 workflow-controlled predicate를 독립 권위로 승격하지 않는다.
  같은 trusted run에서 `actions/attest`가 반환한 absolute bundle은 별도 `verifyBundleWith` 경로가 exact `--bundle` option으로만
  소비한다. 이 경로는 inherited environment와 `GH_TOKEN` 없이 `GH_PROMPT_DISABLED=1`만 전달하고 API 조회로 fallback하지 않으며,
  검증 stdout은 API형과 동일한 strict `parseAndBind`를 통과한다. 이 leaf는 bundle pathname의 filesystem 권위를 만들지 않으며
  후속 composition이 artifact와 bundle을 각각 no-follow pin하고 child 전후에 재검증해야 한다.
  `test-session-host-release-adapter-github-attestation`이 Debug·ReleaseFast에서 command와 semantic authority의 성공 및
  API형과 bundle형의 exact argv·서로 다른 clean environment·pathname 거부·supplied capture, identity/run/subject mismatch,
  duplicate/malformed/cap/timeout/child failure를 검증한다. CLI와 bundle pathname pin/revalidation과 이
  transport의 최종 조립, release attestation·predecessor download·workflow 배선은 후속 범위다.
  baseline evidence를 process 사이에 넘길 때는 `DurableEvidence`가 ephemeral workspace의 exact direct child인 held source를
  read 전후 재검증하고 workspace 밖 absolute destination에 exclusive publish한다. destination owner는 held/path inode와 SHA를
  재검증하며 cleanup 때 exact inode만 unlink하므로 pathname replacement를 삭제하지 않는다. `closeRetaining()`은 descriptor만
  닫고 durable leaf를 남긴 뒤 non-reusable tombstone으로 수렴해 과거 process-local owner의 삭제 권한을 소멸시킨다.
  `test-session-host-release-adapter-candidate-evidence-handoff`가 Debug·ReleaseFast에서 실제 승격과 source workspace 제거 뒤 생존,
  path/alias/final-address/source-drift/existing-destination 거부, retained close 뒤 bytes 생존·owner 재사용 차단, allocation failure와
  identity-safe cleanup을 검증한다. 그 위의
  `test-session-host-release-adapter-candidate-aggregate-handoff`는 evidence와 candidate DMG·frozen executable·evidence·manifest
  local bundle 네 개를 닫힌 role 집합으로 받아 staging directory 전체를 sync한 뒤 absent final directory에 no-replace rename하는
  atomic publication을 검증한다. Debug·ReleaseFast 실제 filesystem 행은 publish와 cleanup 양쪽의 partial final visibility 0,
  source·destination inode/SHA, replacement 보존, cleanup tomb retry, retained close 뒤 생존과 옛 owner 권한 소멸을 고정하며 harness-owned 임시 루트의 APFS 40회 실측에서 단계별
  median·p95·max, 실패 수, FD delta와 staging residue를 남긴다. opaque bundle의 artifact-role 교환 판정은 handoff가 아니라 다음
  process의 §11.47 exact-subject 검증이 소유한다. split prepare/finalize reopen·semantic binding과 live workflow wiring은 후속 범위다.
  `release_adapter_github_release_attestation.zig`는 post-publish release와 local asset에 대해 exact
  `gh release verify <tag>`/`verify-asset <tag> <absolute-file>` argv, clean token environment와 bounded stdout을 소유한다.
  verified release statement의 exact repository ID/release ID/tag/purl, purl subject의 tag-ref SHA-1과 manifest가 열거한
  세 asset 및 canonical manifest 파일 자체를 합친 attached artifact 네 개의 name/SHA-256 exact set을 결속하고
  certificate SAN과 verified timestamp를 요구한다. `ownerId`는 canonical nonzero만
  검사하며 별도 owner 권위로 쓰지 않는다. tag-ref SHA를 annotated tag의 peeled source commit으로 오인하지 않고 후속
  composition이 기존 git resolver의 manifest commit 수렴 증거와 함께만 `ReleaseAttestation.source_commit`을 만든다.
  `test-session-host-release-adapter-github-release-attestation`이 Debug·ReleaseFast에서 release/asset command, statement와
  manifest 포함 attached artifact set, local selection, malformed/duplicate/cap/timeout/child failure를 검증한다. CLI pin/revalidation, predecessor
  download, git resolver 조립과 workflow 배선은 여전히 후속 범위다.
  `release_adapter_github_download.zig`는 canonical manifest의 세 asset role exact set을 role 순서로 다운로드한다. exact asset
  name은 Go filepath glob metacharacter를 escape한 뒤 `gh release download <tag> --repo ohah/maru --pattern <literal>
  --output -`로만 선택하며 `--dir`/clobber/latest/archive를 허용하지 않는다. exclusive 0700 work-directory와 각 0600 leaf를
  descriptor-relative `O_EXCL|O_NOFOLLOW`로 먼저 소유하고, manifest size를 `F_PREALLOCATE`+`ftruncate`한 exact shared mapping에
  bounded stdout을 받아 exact length/SHA-256, mapping provenance, post-write identity/link-count 1, `msync`/file+directory fsync 뒤 0400으로
  봉인한다. 실패는 owned inode만 제거하고 residue 0을 확정하지 못하면 cleanup failure다. 성공은 세 path/identity/digest를 가진
  move-only `DownloadedSet`으로만 반환한다. `test-session-host-release-adapter-github-download`이 Debug·ReleaseFast에서 command,
  clean environment, actual filesystem/mapped write와 path·identity·digest 결과, glob·short/long/digest·symlink/existing
  work-directory·timeout/child failure와 cleanup을 검증한다. CLI pin/revalidation, release verify-asset와 final workflow
  composition은 후속 범위다.
  `release_adapter_github_manifest_download.zig`는 current B manifest의 verified predecessor tag/SHA에서 provisional exact manifest
  name을 만들고 fixed `gh release download <tag> --repo ohah/maru --pattern <literal> --output -`로만 bootstrap bytes를 얻는다.
  이 argv와 literal pattern SSOT는 세-asset downloader도 공유하는 `release_adapter_github_download_command.zig`다.
  `release_manifest.max_manifest_bytes` caller buffer provenance와 non-empty output/SHA-256을 닫고 inherited environment 없이 exact
  token만 전달한다. 결과는 아직 JSON 의미나 asset allocation 권위가 아니며 후속 artifact attestation과 strict parse가 parsed
  A tag/version/name 및 B predecessor tag/SHA를 교차검증해야 한다. `test-session-host-release-adapter-github-manifest-download`이
  Debug·ReleaseFast에서 exact name/argv/environment, malformed identity/input bounds, foreign/empty/oversize/digest mismatch와
  timeout/child failure를 검증한다. attestation/parse cross-binding, 세 asset download와 final workflow composition은 후속 범위다.
  executable `fetchUntil`은 같은 final-address deadline을 pinned CLI 재검증 전후와 `Observed` publication 직전에 확인하고
  두 번째 fresh remaining만 manifest download child에 전달한다. malformed preflight는 deadline·CLI·child 0, 재검증 중
  또는 child 후 만료는 publication 0이며 focused gate가
  injected exact 순서와 product wrapper compile을 두 optimize mode에서 함께 고정한다.
  predecessor manifest input composition은 authenticated current B에서 predecessor expectation을 유도하고 exact workspace
  `predecessor-manifest` child에서 download→materialize→canonical A cross-bind→attestation을 같은 deadline/CLI로 실행한다. historical
  protected-tag 상태는 합성하지 않고 B의 exact A endorsement와 A manifest artifact attestation을 결속하며, current publication의
  protected-tag admission은 유지한다. 성공 owner는 authenticated A와 descriptor cleanup만 보존해 caller buffer reuse와 copy 거부를
  고정하고, 중간 실패는 actual filesystem residue 0이다.
  `test-session-host-release-adapter-github-predecessor-manifest-input`이 두 optimize mode에서 이 ordering·cleanup·제품 wrapper를 검증한다.
  `release_adapter_github_manifest_file.zig`는 attestation CLI에 줄 fixed provisional manifest file만 소유한다. absolute absent
  0700 work-directory와 exact-name 0600 leaf를 descriptor-relative exclusive/no-follow로 만들고 bounded bootstrap bytes 길이를
  preallocate·truncate·complete write한 뒤 SHA, pathname↔fd identity/type/size/link-count 1, 0400 mode와 file/directory fsync를 봉인한다.
  move-only result만 path/identity/digest를 노출하고 explicit cleanup은 owned inode와 exact directory만 제거한다.
  `test-session-host-release-adapter-github-manifest-file`이 Debug·ReleaseFast actual filesystem에서 success/copy/existing/symlink,
  digest/name/empty/cap의 publication 0과 success cleanup residue 0을 검증한다. write/pathname identity drift 주입과 cleanup
  불확실성의 foreign-entry 보존, attestation과 strict parse/cross-binding은 후속 범위다.
  `release_adapter_github_manifest_attestation.zig`는 B predecessor에 없는 A build run identity를 얻기 위해 bounded A bytes를 먼저
  strict/intrinsic parse하되 unauthenticated candidate로만 보유한다. role=A/predecessor 부재와 B↔A release ID/tag/source commit/
  manifest SHA/canonical filename을 교차검증하고, candidate repository/tag/source/build로 기존 artifact attestation verifier를 호출하며
  candidate repository/tag/source/build에서 historical protected-tag 값을 합성하지 않고 fixed manifest file identity를 호출 전후
  재검증한 뒤에만 move-only `AuthenticatedManifest`를 게시한다. candidate의 `assets[]`는 이
  publication 전에는 filesystem allocation/download 권위가 아니다. `test-session-host-release-adapter-github-manifest-attestation`이
  Debug·ReleaseFast에서 parse/cross-binding, existing verifier composition, file drift, copied owner, mismatch/child/allocation failure의
  publication 0과 unwind를 검증한다. 같은 gate의 published-A 행은 post-publish current protected context를 role-A manifest의
  repository/tag/source/build와 직접 결속하고 같은 file/attestation/deadline 규율로 인증한다. deadline/result/output과
  bytes/file/context/token/pinned CLI, parsed backing alias는 외부 권위 전에 거부한다. successor B predecessor self-synthesis,
  role B와 unprotected/current-context drift는 publication 0이다. predecessor asset download/release verify-asset/git resolver/final
  workflow는 후속 범위다.
  `release_adapter_github_predecessor_assets.zig`는 move-only authenticated A manifest만 asset allocation 권위로 받아 기존
  downloader·release attestation·git resolver를 조립한다. CLI는 각 외부 호출 직전, 다운로드 set은 각 release/asset 검증 전후에
  path/device/inode/type/link-count/mode/size/SHA-256과 work-directory pathname identity를 재검증한다. release purl SHA-1은 첫
  tag-ref target에 결속하고 annotated chain은 resolver가 manifest source commit까지 별도로 peel한다. 전 호출과 수렴 뒤에만
  move-only authenticated asset owner를 게시하며 실패는 residue 0 또는 terminal cleanup failure다.
  `test-session-host-release-adapter-github-predecessor-assets`가 Debug·ReleaseFast에서 lightweight/annotated 성공, exact 호출·재검증,
  statement/ref/commit과 filesystem drift, copied owner, child/OOM/depth/cycle failure의 publication 0·cleanup을 검증한다. workflow
  wiring, Apple product 판정과 frozen release 제품 E2E는 후속 범위다.
  `release_adapter_github_tag_chain_transport.zig`는 제품 annotated-tag 상한을 8 hop으로 고정하고 `tag_ref` 뒤 resolver가
  요구한 exact `annotated_tag`만 순차 조회한다. 매 요청 전 CLI를 재검증하고 reusable JSON buffer의 borrowed parser slice를
  fixed owned hop record로 복사하며, 최초 positive monotonic absolute deadline 하나를 ref/tag fetch와 후속 asset composition
  전체가 공유한다. lightweight는 annotated fetch 0, commit 뒤 추가 관측 0이며 9번째/cycle/foreign/mismatch/CLI drift/deadline은
  publication·residue 0이다. `test-session-host-release-adapter-github-tag-chain-transport`가 Debug·ReleaseFast에서 0/1/8-hop,
  exact request/revalidation/deadline 감소, buffer reuse, 9-hop/cycle/mismatch/OOM을 검증한다. repository/run/environment/deployment와
  workflow/U5 배선은 후속 범위다.
  current GitHub authority composition은 strict `Context`와 pinned CLI에서 repository, current workflow run, configured `release`
  environment, attempt jobs, source/tag/environment deployments와 candidate별 status history를 closed request 순서로 조회한다. 매
  request 전 CLI를 재검증하고 최초 monotonic absolute deadline 하나를 공유한다. deployment parser의 two-phase
  `prepare`/`finish`가 jobs·deployments를 한 번만 parse해 최대 100개 candidate ID를 소유하고 exact-one status backing을 요구한 뒤,
  recognized protection과 exact job URL의 pending→in_progress 이력을 하나의 deployment에 결속한다. 성공은 move-only
  `CurrentGitHubAuthority`의 repository/run/job/deployment/environment ID, source commit과 `protected_environment=true`로만
  게시된다. `test-session-host-release-adapter-github-current-authority`가 Debug·ReleaseFast에서 exact request/revalidation,
  reusable buffer, 0/1/100 candidate, status backing mismatch, owner copy, deadline/CLI/child/OOM failure의 publication 0을 검증한다.
  current release authority composition은 context↔manifest를 외부 호출 전 결속하고, 이 current authority 전체 뒤
  authenticated paginated 목록의 exact-one mutable draft release와 최대 8-hop tag chain을 manifest release/source에 교차검증한다. predecessor와 current는
  fixed owned hop·resolver·cycle/depth 정책의 하나의 helper를 공유하며, 전 request가 하나의 absolute deadline과
  request 직전 CLI 재검증을 공유한다. 성공은 current authority ID, draft release ID/tag, source commit,
  protected-environment fact를 move-only `CurrentReleaseAuthority`로만 함께 게시하고 중간 current authority를 노출하지
  않는다. `test-session-host-release-adapter-github-current-release-authority`가 Debug·ReleaseFast에서 exact 전체 sequence,
  lightweight/1/8-hop, 9-hop/cycle/mismatch, buffer overwrite, single deadline, owner copy·CLI/child/OOM publication 0을 검증한다.
  current manifest artifact attestation, 최종 command/workflow 조립, Apple product 관측과 frozen U5 E2E는 후속 범위다.
  Current manifest attestation composition은 current B canonical bytes를 strict context와 move-only current release authority 전체에
  결속하고, caller pathname 대신 기존 descriptor-owned `ManifestFile`의 canonical name/computed SHA와 before/after
  identity·type·0400·link-count-1을 검증하면서 pinned CLI artifact attestation을 재사용한다. 성공은 parsed manifest와 current
  authority identity를 move-only `AuthenticatedCurrentManifest`로만 함께 게시한다.
  `test-session-host-release-adapter-github-current-manifest-attestation`이 Debug·ReleaseFast에서 role/predecessor/context/current
  authority/file mismatch, before/after drift, owner copy와 CLI/attestation/OOM publication 0을 검증하고, certificate·subject 세부
  변조는 재사용하는 artifact-attestation gate가 소유한다. local asset·Apple product 관측,
  summary·executable·workflow 배선과 frozen U5 E2E는 후속 범위다.
  Current manifest pathname composition은 canonical basename의 absolute caller path를 기존 no-follow file reader로 한 번만 읽어
  owned bytes·computed digest를 만들고, 그 값만 descriptor-owned private `ManifestFile`로 materialize한 뒤 current attestation에
  넘긴다. 성공은 input bytes·cleanup capability·`AuthenticatedCurrentManifest`를 move-only `CurrentManifestInput` 하나로만
  게시한다. `test-session-host-release-adapter-github-current-manifest-input`이 Debug·ReleaseFast 실제 filesystem에서 원본 read 뒤
  mutation 격리, attestor private pathname, basename/symlink/type/size/read/materialization/attestation 실패의 publication·residue 0,
  copied/pre-owned owner와 allocation unwind를 검증한다. local DMG/frozen executable·Apple product 관측,
  summary·executable·workflow 배선과 frozen U5 E2E는 후속 범위다.
  Frozen executable pathname authority는 전체 binary를 heap에 복사하지 않고 기존 release adapter file SSOT의
  `PinnedExecutableFile`에 no-follow executable fd를 보존한다. manifest expected size/SHA-256과 제품 상한을 64 KiB stack-buffer
  streaming hash로 결속하고, 후속 관측 전후 pathname hash·reopened pathname fd·held fd의 identity/type/mode/link-count/size/time/
  digest를 재검증한다. `test-session-host-release-adapter-frozen-executable-authority`가 Debug·ReleaseFast actual filesystem에서
  move-only owner, invalid type/mode/expected values, symlink·pathname replacement·in-place mutation을 검증한다. DMG 내부 executable
  동일성, Apple product/current manifest composition, summary·executable·workflow 배선과 frozen U5 E2E는 후속 범위다.
  Current local product composition은 authenticated `CurrentManifestInput`만 받아 그 manifest의 exact DMG/frozen asset expectation과
  version을 사용한다. 공통 release asset cap은 `release_adapter_files.max_release_asset_bytes`가 소유하고 downloader·DMG·frozen
  경계가 재사용한다. `release_adapter_github_current_product.zig`는 frozen pin/revalidation 전후에 기존 DMG authority를 호출하고,
  DMG 내부 product SHA와 frozen SHA 및 manifest signing과 Apple observation을 기존 manifest policy helper로 대조한 뒤에만 held fd와
  owned Apple observation을 move-only로 게시한다. `test-session-host-release-adapter-github-current-product`가 Debug·ReleaseFast에서
  authenticated/move-only/path/asset/cap/signing/digest/mutation/failure/cleanup/allocation 경계를 검증한다. 실제 mount/Apple command와
  residue는 기존 DMG authority gate가 소유하며 compatibility/evidence/asset attestation/final observation과 workflow/U5 배선은 후속이다.
  Current evidence provenance composition은 move-only authenticated current B와 predecessor A manifest만 identity SSOT로 받아 B의
  summary asset basename·size·SHA와 evidence fields, B↔A predecessor 및 A asset set을 다시 교차검증한다. caller identity scalar 없이
  B에서 current common/candidate/test UUID/signer를, A에서 predecessor release/manifest/DMG/executable digest를 유도해 no-follow bounded
  read한 canonical `upgrade_b` evidence에 bind하고 owned bytes+file observation+parsed value를 final-address `CurrentEvidence`로 게시한다.
  `test-session-host-release-adapter-github-current-evidence`가 Debug·ReleaseFast actual filesystem에서 owner/copy/path/inode alias,
  summary/A/B/candidate/predecessor/signer/UUID drift, malformed bytes와 allocation unwind publication 0을 검증한다. summary artifact
  attestation, compatibility·세 current asset attestation, final observation과 workflow/U5 배선은 후속이다.
  Release adapter absolute deadline은 `release_adapter_deadline.zig`의 final-address owner가 positive budget과 단일 monotonic 관측을
  absolute expiry로 exact once 봉인한다. `test-session-host-release-adapter-deadline`이 Debug·ReleaseFast에서 non-increasing remaining,
  exact expiry, rollback·overflow·zero/negative budget, copy/pre-owned 거부와 real product leaf compile을 검증한다. 이 component 증거만으로
  하위 composition의 같은 pointer 소비나 전체 phase/workflow 완료를 주장하지 않는다.
  Current asset private-file composition은 authenticated current B manifest와 move-only current product/evidence에서 exact three-role
  name·size·SHA와 source identity를 유도한다. held frozen fd 재검증, DMG no-follow streaming read, owned evidence bytes를 source로 삼아
  absent 0700 directory의 exact-name 0400·link-count-1 leaves에 complete copy·sync하고, large asset을 heap에 올리지 않은 채 source와
  destination digest 및 pre/post fingerprint를 닫는다. `test-session-host-release-adapter-github-current-asset-files`가
  Debug·ReleaseFast actual filesystem에서 success/move-only cleanup, four-source inode distinct, path/role/size/digest drift,
  symlink/alias/mutation/collision, allocation-free fixed storage, I/O failure publication 0과 cleanup retry를 검증한다. GitHub attestation, compatibility,
  final observation과 workflow/U5 배선은 후속이다.
  Bounded process held-directory substrate는 async-signal-safe fork child의 `fchdir`와 fd 3 이상 전량 폐쇄를 사용해
  caller의 valid open directory fd가 가리키는 exact vnode를 child cwd로 고정한다. 기존 non-directory 실행도 stdio 외 ambient
  descriptor가 외부 verifier로 새지 않고, parent fd의 flags/identity/ownership은 바꾸지 않는다.
  `test-session-host-bounded-process`가 Debug·ReleaseFast actual process에서 exact `./leaf` read, sibling ambient fd 비상속,
  regular/stdio/closed fd pre-spawn 거부와 parent owner 불변을 기존 timeout/cap/status/environment 행과 함께 검증한다. 이 substrate는
  current asset attestation semantic composition과 workflow/U5 배선을 대신하지 않는다.
  `release_adapter_github_current_asset_attestation.zig`는 authenticated current B manifest와 final-address
  `CurrentAssetFiles`를 조립해 canonical three-role 순서의 `gh attestation verify ./<exact-name>`만 held directory cwd에서 실행한다.
  하나의 absolute deadline, command별 pinned CLI 재검증, held directory와 세 private leaf의 identity·0400·link-count 1·size/SHA
  pre/post 재검증, 기존 certificate/context/run/subject semantic binder를 모두 통과한 뒤에만 move-only 세 observation을 게시한다.
  `test-session-host-release-adapter-github-current-asset-attestation`이 Debug·ReleaseFast actual process와 injected failure에서 exact
  order/argv/cwd, budget 감소, role/context/subject·CLI·filesystem drift, copied/pre-owned owner, partial success 뒤 command/OOM 실패의
  publication 0과 observation 역순 cleanup을 검증한다. 이 gate는 release verify/verify-asset, compatibility, final observation,
  workflow 또는 frozen U5 E2E 완료 증거가 아니다.
  `release_adapter_github_cli_authority.zig`는 공식 GitHub Release CI만 대상으로 checkout 전 캡처한 canonical absolute `gh`
  path와 lowercase SHA-256, exact `GITHUB_WORKFLOW_SHA`/GitHub-hosted macOS ARM64 runner observation을 결속한다. macOS filesystem
  leaf는 no-follow regular executable의 device/inode/size/digest를 기록하고 transport 호출 직전 같은 pathname을 재관측해
  symlink·교체·mutation을 fail-close한다. `test-session-host-release-adapter-github-cli-authority`가 Debug·ReleaseFast에서 runner
  observation과 실제 filesystem 변조 행을 검증한다. 로컬 빌드·로컬 앱 인증서 upgrade에는 이 권위를 요구하지 않으며, focused
  gate만으로 checkout 전 capture와 transport 배선이 완료됐다고 주장하지 않는다.
  `check-session-host-release-workflow`는 실제 `.github/workflows/release.yml` bytes에서 tag-only trigger, protected `release`
  environment, macOS ARM64 runner label, checkout 전 exact-one GitHub CLI capture, canonical regular executable와 lowercase SHA-256의
  step-output handoff, pinned Action과 `GITHUB_ENV` 미사용을 정적으로 고정한다. repository checkout이 capture보다 앞서거나 checkout
  뒤 PATH를 다시 조회하는 변경은 fail-close한다. 이 gate는 실제 GitHub service provenance, captured output의 validator argv 소비,
  manifest/evidence 생성·attestation·publication 또는 signed frozen U5 E2E를 대신하지 않는다.
  `release_adapter_candidate_attestation.zig`는 draft/release ID 없이 trusted tag context와 exact universal DMG/frozen executable pathname만
  받아 두 asset을 no-follow held fd로 pin하고 canonical DMG→frozen 순서로 GitHub artifact attestation에 결속한다. subject name/SHA와
  repository/tag/source/build는 caller scalar가 아니라 context와 held-file view에서 유도한다. 같은 final-address deadline과 pinned CLI를
  두 child 전체가 공유하고 각 command 전후 file/CLI authority 및 마지막 publication 시각을 재검증한다. focused gate는
  Debug·ReleaseFast actual filesystem+injected attestor에서 distinct inode/cap/execute bit, exact order와 감소 budget, copied/pre-owned owner,
  path/context/subject mutation, 중간·최종 expiry, partial observation/OOM unwind의 publication 0을 검증한다. draft 생성과 post-draft release
  ID 결속, Apple product/evidence/manifest/workflow는 후속 gate다.
  `release_adapter_github_draft_creation.zig`는 checkout 전 pinned CLI와 trusted context를 사용해 exact repository release endpoint에
  mutable draft를 한 번 생성하고 response의 nonzero ID·tag·target source·title·draft/prerelease/immutable state를 final-address
  `DraftAuthority`로 결속한다. mutation endpoint/method/fields는 closed vocabulary이며 기존 release 재사용, caller-provided ID,
  재시도와 `--clobber`는 금지한다. remote create 뒤 local parse/OOM이 실패하면 성공이나 부재를 가장하지 않고, ID 결속 뒤에는
  exact created-ID cleanup-required를, 결속 전에는 ID 없는 remote-state-unknown terminal을 남긴다. focused gate는 Debug·ReleaseFast에서 exact argv/environment/deadline/CLI revalidation,
  malformed/drift/existing/child failure, copied owner와 allocation fail-index를 검증한다. 실제 GitHub mutation 성공, evidence/manifest
  authoring, draft asset attach와 publish는 후속 workflow gate가 소유한다.
  `release_adapter_candidate_files.zig`는 pre-draft `CandidateAttestation`의 held-file/attestation view를 raw pathname 재-pin 없이
  revalidate하고 trusted tag context와 move-only draft ID/tag/source에 결속한다. success owner는 final-address attestation owner를
  빌리며 자신이 먼저 cleanup되어야 한다. focused gate는 Debug·ReleaseFast에서 copied/pre-owned/stale attestation, context/draft/name,
  pathname replacement·in-place mutation, owner lifetime과 publication 0을 검증한다. Apple signing, DMG 내부 executable equality와
  evidence/manifest authoring은 이 gate의 완료 범위가 아니다.
  `release_adapter_candidate_product.zig`는 final-address candidate file owner가 차용한 pre-draft attestation의 DMG/frozen 관측만 사용해 기존 DMG authority에 exact
  expected size/SHA와 tag version을 넘기고, Apple 관측 전후 source를 revalidate한다. DMG 내부 executable SHA는 held frozen SHA와
  exact 일치해야 하며 signing은 owned Apple observation에서만 유도한다. focused gate는 Debug·ReleaseFast actual filesystem과 injected
  observer로 shared deadline, exact input derivation, path/work alias, copied/pre-owned owner, source mutation·observer failure·digest mismatch와
  allocation unwind publication 0을 검증한다. 실제 mount/command residue, GitHub artifact attestation과 evidence authoring은 별도 gate다.
  `release_adapter_github_source_tree.zig`는 trusted tag context의 exact source commit을 기존 pinned CLI·token·phase deadline으로
  GitHub Git commit object에 조회하고, 응답 top-level commit SHA와 nested tree SHA를 strict parse해 final-address owner로 게시한다.
  로컬 checkout·ambient `git`·caller tree scalar는 authority가 아니다. focused gate는 Debug·ReleaseFast에서 closed endpoint,
  deadline/CLI pre-post 순서, foreign capture와 output/authority alias, malformed·duplicate·missing·commit/tree drift, copied/pre-owned
  owner와 allocation fail-index publication 0을 검증한다. evidence aggregate/manifest writer와 release publication은 별도 gate다.
  `release_adapter_candidate_evidence_identity.zig`는 trusted context·canonical UUID v4·revalidated candidate product·source-tree
  owner만 받아 release ID/version, commit/tree, build와 candidate/signing digest를 `evidence.Common` 기반 final-address storage로
  복사한다. UUID/common 검증은 `release_evidence.validateCommon`을 SSOT로 사용하며 후속 소비 전 product/tree를 다시 검증한다.
  focused gate는 Debug·ReleaseFast에서 exact derivation, copied/pre-owned owner, UUID/context/product/tree/path drift와 owner storage
  독립성을 검증한다. profile/predecessor, leaf aggregate publication과 attestation은 별도 gate다.
  `release_adapter_predecessor_evidence_identity.zig`는 authenticated role-A manifest·held manifest file·authenticated downloaded
  asset set만 받아 release/tag/source와 manifest·DMG·frozen executable digest를 fixed `evidence.Predecessor` storage로 유도한다.
  attestation subject SHA와 held manifest digest, manifest asset role별 name/size/SHA와 downloaded inode observation, resolved source를
  compose와 revalidation 때 모두 exact 비교한다. focused gate는 Debug·ReleaseFast actual filesystem에서 copied/pre-owned/alias owner,
  role/source/asset 교환·누락·mutation과 attestation/file mismatch의 publication 0을 검증한다. upgrade leaf 조립·publication과 U5
  frozen 제품 실행은 별도 gate다.
  Apple 제품 component 판정자는 frozen executable SHA와 bounded codesign detail/requirement, plist JSON, lipo architecture 및
  strict signature·app/DMG staple·DMG Gatekeeper 성공 receipt를 교차검증해 `Signing`을 직접 만든다. identifier/team의 exact-one,
  Apple team designated requirement digest와 따옴표 밖 disjunction·negation 거부, `product_identity.bundle_id`·`bundle_version`, release version 결속과 exact `arm64 x86_64`를 닫고
  `test-session-host-release-adapter-apple-product`가 Debug·ReleaseFast에서 mismatch·duplicate·malformed·cap과 allocation
  fail-index unwind를 검증한다. 이
  component green은 실제 command argv 실행, DMG no-follow extraction 또는 receipt 진위를 증명하지 않는다.
  `release_adapter_apple_transport.zig`는 caller가 executable/option을 고르지 못하는 closed command vocabulary로 system
  `plutil`/`codesign`/`lipo`/`xcrun stapler`/`spctl`의 exact argv를 만들고, inherited environment가 없는 bounded child에서
  capture 또는 exit-0 receipt를 얻어 전부 성공한 경우에만 Apple product `Captures`를 조립한다.
  `test-session-host-release-adapter-apple-transport`가 Debug·ReleaseFast에서 exact argv·empty environment·command capture,
  output cap·timeout·child failure와 부분 관측 비게시를 검증한다. pathname no-follow authority와 DMG extraction은 포함하지 않는다.
  transport와 component parser를 하나의 adapter observation으로 조립하는 executable, 실제 codesign·DMG 관측, canonical summary encoding,
  release workflow 배선은
  아직 없으므로 외부 release 검증은 후속 슬라이스가
  추가한다. 현재 일반 PR의
  component/fixture green은 이 선결조건들을 대신하지 않는다. 일반 DMG release의 draft-first·no-clobber·재다운로드 byte
  equality는 연결됐고 release workflow의 third-party Action은 exact SHA로 고정했으며 임의 ref를 고를 수 있는 수동 실행은
  제거했다. session-host manifest/evidence attestation과 post-publish release attestation은 아직 없다. 2026-08-27 GitHub
  API 감사에서 repository self-hosted runner, Actions Secret, deployment environment, tag ruleset은 각각 0개였으므로
  Developer ID 출하와 전용 Aqua 제품 gate는 `not_provisioned`다. repository-level release immutability는 공개 REST 응답으로
  판정하지 못했으며 manifest validator 배포 뒤 Settings에서 켜고 이후 release에만 적용된다는 사실을 별도 확인해야 한다.
- **release gate:** B manifest가 exact predecessor release A의 immutable release ID·tag·commit과 DMG/내부 제품 executable
  SHA-256을 지목하고, release attestation·artifact attestation·Developer ID identity를 validator가 교차검증한다. SemVer 숫자의
  산술 인접성이나 `latest` 조회로 A를 추측하지 않는다. manifest가 지목하지 않은 downgrade는 지원하지 않는다.
- **config gate:** `missing|readable_absent`만 atomic explicit `true` materialization 성공 뒤 true로 publish한다.
  `explicit_valid(value)`는 그대로, `explicit_invalid|unreadable|oversize`와 write 실패는 false·파일 부분 게시 0이며 persistent
  typed notice를 남긴다. B가 만든 explicit true를 exact A가 읽는 rollback과 A runtime을 B adapter가 exact attach하는 제품
  경로를 함께 검증한다.
- **제품 증거:** signed/notarized A와 B, clean/explicit/malformed config matrix, 2 Window+3 Workspace, PID·runtime·input/output/
  copy/resize, tombstone relaunch, Quit 취소, Notification cold/live click을 같은 test UUID의 구조화 artifact로 묶는다. 결과가
  없거나 manifest/summary가 한 필드라도 다르면 B publish를 실패시킨다. G3 source merge는 출하 완료 증거가 아니다.
