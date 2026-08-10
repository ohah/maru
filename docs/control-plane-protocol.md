# 세션 컨트롤 플레인 — transport·프로토콜 (§4)

핸드셰이크·버전·네임스페이스, 다중 인스턴스 발견, 프레이밍 견고성, bulk payload 전송 계약이다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§8.1`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§3·§5~§7·§10·§13~§15 [control-plane.md](control-plane.md) · §4 [transport·프로토콜](control-plane-protocol.md) · §8 [보안](control-plane-security.md) · §9.1·§9.6 [browser.\* 코어와 CLI](control-plane-browser.md) · §9.2~§9.3 [라이브 배선](control-plane-browser-wiring.md) · §9.4 [프로토콜 리뷰](control-plane-browser-review.md) · §9.5 [지속 세션·이벤트·대용량 결과](control-plane-browser-session.md) · §11~§12·§16 [구현 Phase와 검증](control-plane-implementation.md)

## 4. transport·프로토콜

### 4.1 핸드셰이크·버전·네임스페이스
- 연결 시 server가 `hello` notification으로 `{protocol: "maru.control.v1", server_version, capabilities}`를 보낸다. 외부 도구·CLI↔GUI 버전 skew를 감지하고, 지원 메서드를 capability로 광고한다. **5f-5c 기능 구현과 별개로 Track 5 성능 완료 gate까지 통과한 뒤** capabilities string array에 활성화된 논리 결과 상한 `browser.executeScript.max-result-bytes=16777216`을 추가한다. 5f-5c live 경로는 strict CSP·Promise·args와 16 MiB chunk를 전달하지만 현재 hello에는 이 capability가 아직 없다. 코드의 `execute_script_protocol_max_result_bytes=256 MiB`는 현재 parser나 capability에 연결되지 않은 reserved 상수다. 향후 실험도 넘지 않을 ceiling 후보일 뿐 현재 입력 방어선·지원 약속이 아니며, §4.4 재검토 뒤 실제 parser에 연결할 때 별도 테스트로 고정한다(§9.5.8).
- 메서드 네임스페이스를 예약한다: 코어 = `sessions`/`session`/`panel`/`browser`, 확장 = `plugin.<id>.*`. 닫힌 하드코딩 테이블이 아니라 코어 표 + 등록 가능한 확장 핸들러로 디스패치해 plugin/MCP/skill을 막지 않는다. 발견 메서드(`methods.list`)는 후속.
- CR 단계에서 외부 control-plane에 `Retry`, `Take Control`, paused-paste resend/discard RPC를 노출하지 않는다. 이 action은
  fresh GUI gesture와 single-use authority가 필요한 제품 UI 전용이다. CR6에서 외부 API 요구가 생기면 capability·nonce·TTL을
  별도 설계한다. 상태 구독을 구현할 때는 기존 surface lifecycle event에 위 일시 상태를 typed 값으로 싣고 raw host error는
  보내지 않는다.

### 4.2 다중 인스턴스·발견
- 소켓 경로 키 = 인스턴스(pid/부팅 nonce). `~/.cache/maru/control/`(0700)에 살아있는 인스턴스 인덱스 + `flock`.
- bind 전 stale 소켓은 `flock`으로 살아있는지 판별 후 unlink-then-bind(살아있는 소켓은 unlink 금지).
- **stale prune(flock 회수, 구현: `control_socket.pruneStaleSockets`)**: 위 판별은 **자기 키**의 잔해만 처리한다. crash/force-quit로 `deinit`(소켓 unlink)이 못 돈 인스턴스는 `<key>.sock`+`<key>.lock`을 남기는데, 다음 실행은 새 nonce로 **다른** 키의 소켓을 bind하므로 그 잔해가 dir에 계속 쌓여 `.sock`이 여럿이 되면 CLI `pickSocket`이 `.multiple`로 접혀 `maru sessions list`가 영구 고장난다. 이를 막으려고 **서버 start(bind)마다** dir의 각 `<key>.sock`(자기 키 제외)에 대응하는 `<key>.lock`을 non-blocking `flock(EX|NB)`으로 회수 시도한다: 취득되면(=소유 인스턴스 죽음, fd가 닫혀 flock 자동 해제) 그 `.sock`+`.lock`을 unlink하고 flock 해제, 살아있는 인스턴스는 lock을 홀드 중이라 취득 실패→보존한다(`.lock`이 아예 없는 고아 `.sock`도 liveness 증거 부재로 회수). readdir 중 unlink는 POSIX 미정의라 key를 먼저 모은 뒤 처리한다. best-effort.
- 자식 셸은 `$MARU_SESSION`+소켓 경로로 자기 인스턴스를 안다. `$MARU_SESSION`은 `{instance_nonce, surface_id, generation}`을 담은 **selector**일 뿐이고 비밀 bearer token이 아니다. `window_id`/`window_token`/`window_kind`는 응답 메타데이터로만 노출되는 현재 위치 정보다. `metadata:self`는 이 selector가 가리키는 surface와 peer process의 OS 관측 출처가 일치할 때만 열린다(§8.4). `read-output` 이상은 spawn 시 상속한 capability fd(§8.5)가 증명한다. maru 밖 일반 셸의 CLI는 단일 인스턴스면 자동 발견까지만 가능하고, 비밀 출력 열람은 별도 grant가 필요하다(어휘 미정 — §13).

### 4.3 프레이밍 견고성
- max frame size(≈ 1 MiB) 정의. 이 값은 request·response·notification **각 NDJSON 물리 프레임**의 상한이지, chunk로 전달하는 논리 결과 전체의 상한이 아니다. 인바운드 프레임 초과 시 `payload-too-large` + 연결 종료, 부분 읽기는 누적 버퍼. 대형 결과 때문에 이 전역 상한을 256 MiB로 키우면 작은 요청 하나로도 프레이머 메모리·parse 비용을 증폭할 수 있으므로 금지하고, 아래 chunk 경로로만 총량을 넓힌다. maru가 impl-defined server-error 범위(-32000~-32099, JSON-RPC이 미지정)에서 택한 코드(구현: `src/session/control_plane.zig` `ErrorCode`): **-32001 `payload-too-large`**(물리 프레임, §4.3), **-32002 `unauthorized`**(§8.3 — scope 판정을 존재검사 이전에 하는 균일 오류, surface_id 열거 oracle 방지), **-32003 `process-exited`**(인가된 호출자가 물었으나 surface가 없을 때만 — 이미 볼 권한이 있어 oracle 아님), **-32004 `timeout`**, **-32005 `result-too-large`**(인가·실행은 성공했으나 bounded serializer가 요청한 논리 총량 상한을 초과; 연결 유지, `data={limit_bytes,observed_bytes_at_least}`, §9.5.8), **-32006 `script-error`**(`data={kind:"execution"|"serialization"|"navigation",name,message,stack?,diagnostics_truncated?}`; 최종 escaped error frame 32 KiB 상한), **-32007 `resource-busy`**(실행 전 자원 부족, `data={resource,retryable:true}`; `resource`는 `browser-result-bytes` 또는 `browser-execution-slots`). `max_result_bytes`가 0·비정수·protocol hard max 또는 hello가 광고한 현재 effective max를 초과하면 `invalid-params(-32602)` + `data={max_allowed_bytes}`다. 표준 코드(parse -32700·invalid request -32600·method not found -32601·invalid params -32602·internal -32603)는 명세 그대로.
- 대형 응답(`capture` 전체 스크롤백·`browser.screenshot`·큰 `browser.executeScript` 구조화 결과 등)은 단일 ndjson 라인 금지 — chunk notification+완료 마커/최종 응답. **JSON 문자열은 valid UTF-8만 담으므로 임의 바이트(이스케이프 시퀀스·깨진 UTF-8)나 프레임 경계에 독립적인 재조립이 필요한 데이터는 base64로 인코딩**한다. executeScript의 UTF-8 JSON bytes도 문자열 escape·멀티바이트 경계에 따른 프레임 크기 변동을 없애기 위해 chunk 모드에서는 base64를 쓴다(§9.5.8). **capture 일관성: 시작 시 `capture_id`+스냅샷 generation을 고정하고, 각 chunk는 `{capture_id, seq, generation, encoding}`을 싣는다.** chunk 복사는 surface `core_mutex` 아래에서만 수행하되 직렬화는 락 밖에서 한다. chunk 경계에서 generation이 바뀌면 server는 성공 완료 마커를 보내지 않고 `capture-invalidated` 오류/notification으로 스트림을 종료한다. client는 처음부터 재시도한다. **여기서 "generation"은 surface 재생성 카운터(§3)가 아니라 스크롤백 evict/rewrap 카운터다** — 그렇지 않으면 chunk 복사가 tick마다 나뉘는 동안 리더의 evict가 chunk 사이 내용을 shift시켜도 미검출된 torn capture가 성공 완료된다. 반대로 바쁜 surface에서 매 chunk마다 evict가 일어나 영원히 완료 불가·무한 재시도가 되지 않도록, 재시도 상한을 넘으면 "첫 락에서 전체 스크롤백을 1회 복사(락 보유·메모리 상한 명시)" 경로로 fallback하거나 부분 성공을 반환한다.
- per-connection bounded outbound 큐 + non-blocking write. 응답을 안 읽는 클라이언트가 디스패처를 막지 않게 한다. 이벤트는 느린 구독자에 대해 coalesce/drop(상태 스냅샷이라 손실 허용), 한계 초과 시 구독 강제 해제.

**5f-5 구현 상태 주의**: 5f-5c 기능까지 live다. 실행 전 `ActiveBrowserExecution` 등록과 process-global 256 MiB 예약, 부족 시 `resource-busy`, queued/running timeout·surface/grant revoke·late callback 정리를 적용한다. v119에서 도입된 Swift immutable `Data` registry와 Zig pull/copy/release 계약(현재 app host ABI v120)이 raw strict-JSON ≤512 KiB를 inline으로 읽고, 그 초과~16 MiB와 screenshot ≤12 MiB를 공통 progressive pump로 보낸다. off-main syntax validation 뒤에는 같은 ABI가 running+pending+현재 인가를 재확인해 revoke/expiry/timeout 후 page side effect 시작을 막는다. execution 예약은 `ActiveBrowserTransfer`로 반환 없이 원자 이관하며 terminal 순서는 **Swift Data 제거 확인 → execution 예약 반환**이다. release callback이 제거를 확인하지 못하면 예약을 유지하고 stop의 Swift `releaseAll` backstop까지 임의 재사용하지 않는다. 연결당 4 MiB/process 32 MiB queued+writer-owned 회계, terminal carve-out, high/low watermark, typed purge와 socket abort가 live 채널에 적용된다. parser는 `max_result_bytes ≤16 MiB`를 검사하고 CLI는 512 KiB scratch+atomic 0600 no-replace spool로 전체 결과를 메모리에 모으지 않는다. `script`는 JavaScript **표현식**이고 `args`는 그 표현식에 주입되는 strict-JSON 배열이다. `callAsyncJavaScript`가 CSP-safe하게 표현식을 직접 컴파일하고 Promise를 await한 뒤 document-start bounded serializer가 host 이전에 결과를 직렬화한다. 여러 statement는 `(async()=>{ ...; return value })()` 같은 표현식으로 감싼다. hello effective-max는 별도 Track 5 성능 gate 전까지 광고하지 않는다. 선언된 256 MiB protocol ceiling은 aggregate 예약 예산과 숫자가 같지만 parser 입력 상한이나 지원 약속이 아니다.

### 4.4 bulk payload 전송의 구현 상태·채택 계약·후속 재검토

§4.3 `resource-busy`의 closed `resource` enum에는 CR 구현과 함께 `session-reconnect`를 추가한다. 이 경우
`data={resource:"session-reconnect",retryable,state,retry_after_ms?}`이고 `state`는 §3의 terminal 일시 상태 enum이며 raw
poison reason은 싣지 않는다. 구현 전 현재 serializer/parser가 이 값을 받는다고 주장하지 않는다.

**프로토콜 결정**: 현재와 5f-5 완료 범위의 application wire는 NDJSON JSON-RPC 2.0 하나뿐이다. 별도 binary frame type, data socket, 파일 경로 반환, `SCM_RIGHTS` data attachment는 구현하거나 협상하지 않는다. base64 chunk는 별도 프로토콜이 아니라 같은 JSON-RPC envelope와 auth/outbound 수명 규칙 안에서 method별 schema로 전달한다. correlation과 terminal은 공통 형식으로 억지 통일하지 않는다: capture는 `capture_id+generation`과 complete/invalidated notification, screenshot은 `capture_id` chunks+final response, executeScript 목표 계약은 `request_id+result_id` chunks+final response를 쓴다.

**현재 live 구현 상태**:

- `browser.screenshot`은 PNG raw bytes를 Swift `BrowserResultTransferRegistry`에 pin하고 앱 전체 공통 pump가 tick당 최대 512 KiB base64 notification 또는 terminal 하나를 enqueue한다. 논리 PNG 상한은 12 MiB이며 final은 `capture_id·seq_total·bytes·width·height·format`을 검증한다. 연결당 4 MiB/process 32 MiB watermark와 typed purge/abort가 live다.
- `browser.executeScript`는 `callAsyncJavaScript` expression+args+await → page-process bounded strict-JSON wrapper → Swift-owned `Data` registry → Zig bounded pull ABI를 사용한다. raw JSON ≤512 KiB는 `{transfer:"inline",result}` 단일 응답, 그 초과~16 MiB는 `browser.executeScriptChunk` notification과 `{transfer:"chunked",result_id,seq_total,bytes}` final이다. pump는 성공 enqueue 뒤에만 offset/seq를 전진시키고 transfer/in-flight의 30초 **무진행** deadline을 함께 갱신한다. 요청 cap 초과는 `result-too-large`, execution/serialization/native WebKit 실패는 bounded `script-error(-32006)`로 끝난다. CLI는 id/seq/bytes와 strict JSON을 streaming 검증한 뒤 atomic spool을 파일 또는 stdout에 공개한다. hello max-result capability만 Track 5 성능 gate 뒤로 보류했다.
- `session.capture` chunk 상태머신은 L2에 있으나 실 scrollback producer/L4 pump/CLI는 아직 미배선이다.

**채택한 5f-5 완료 계약**: executeScript는 base64 전 strict-JSON bytes가 512 KiB 이하이면 inline, 그 이상을 최대 16 MiB까지 base64 JSON-RPC chunk로 전달한다. 512 KiB는 전체 결과 상한이 아니라 inline/chunk 전환점이자 pump의 tick당 raw-copy 상한이며, 물리 JSON-RPC frame 상한 1 MiB와는 별도 축이다. 5f-5b의 progressive pump와 queued+writer-owned byte accounting은 이 16 MiB 경로와 느린 client를 안전하게 다루기 위한 구현 gate다. screenshot도 같은 pump/watermark로 이관하되 raw PNG 논리 상한 12 MiB는 유지한다. 각 숫자의 축은 다르다: screenshot 12 MiB는 raw PNG 총량, executeScript 16 MiB는 base64 전 UTF-8 JSON 총량, 연결당 4 MiB는 동시에 queued+writer-owned인 **serialized wire window**이지 결과 총량 상한이 아니다.

현재 연결 reader는 deferred browser 요청을 기다리는 동안 peer close를 메인 실행 registry에 즉시 통지하지 않는다. 따라서 running executeScript의 연결 종료를 예약 조기 반환 근거로 삼지 않고 backend callback 또는 앱 stop까지 보수적으로 유지한다. 즉시 감지가 필요해지면 stable connection id와 reader/writer 종료 이벤트를 별도 lifecycle 채널로 추가해야 하며, `PendingRequest`나 연결 스택 포인터를 registry에 장기 보존해서는 안 된다.

대체 bulk transport는 다음 두 갈래 중 하나를 artifact로 확인한 뒤 별도 설계 PR에서 재검토한다. **workload trigger**는 현재 전송 성능과 무관하게 제품 요구 자체가 바뀐 경우다. **performance trigger**는 16 MiB 경로에서 [성능 예산](performance-budget.md)의 main tick·RSS·queue 예산을 chunk 축소/off-main 같은 단순 최적화 후에도 만족하지 못한 경우다.

- workload: 정상적인 agent workflow의 결과가 반복적으로 12/16 MiB 논리 상한을 초과한다.
- workload: download, trace archive, video처럼 처음부터 file/stream인 제품 기능이 생긴다.
- performance: base64 encode/decode 또는 JSON string copy가 단순 최적화 후에도 측정 예산을 위반한다.
- performance: 반복 screenshot이 bounded pump로도 필요한 처리량을 내지 못한다.

재검토 시에도 JSON-RPC는 method negotiation·authorization·metadata·error·cancel을 소유하는 **control channel로 유지**한다. 후보는 (a) 명시적으로 협상한 length-prefixed binary frame, (b) authorized request에 single-use nonce로 결합하고 peer credential을 다시 확인하는 별도 data socket, (c) writable fd를 닫고 read-only로 재오픈·검증한 뒤 즉시 unlink해 전달하는 `SCM_RIGHTS` data attachment다. 이 data attachment는 server→이미 인가된 request의 immutable 결과만 운반하며 **권한을 부여하지 않는다**. client→server bearer authority인 §8.5 capability fd와 direction·type·namespace·lifetime을 공유하지 않는다. 전달된 fd는 사후 revoke할 수 없으므로 cancel은 전달 전 cleanup만 보장한다. 단순 파일 경로 반환은 same-uid 유출과 파일 수명 경쟁 때문에 계속 금지한다(§9.5.3). 64/128/256 MiB stress는 [성능 예산](performance-budget.md)의 **후속 연구 gate**이며 현재 roadmap의 활성화 단계가 아니다.
