# Session host 이미지 채널 구현 계획

[Session host 이미지 채널](../session-host-image-channel.md)이 계약의 단일 출처다. 이 문서는 그 계약을 어떤 순서로 현실로 만드는지와
각 단계의 상태·판정자를 소유한다. 계약을 바꿔야 하면 이 문서가 아니라 계약 문서를 먼저 고친다.

## 범위와 불변식

- 모든 단계는 `image_shm` 광고 플래그가 **꺼진 채** 머지할 수 있어야 한다. 앱이 광고를 켜는 것은 IC6 하나다 — 그 전까지 제품
  동작은 지금의 `image_blob` 그대로다. host 의 제공(hello_ack 의 `image_shm`·token, `host_offers_image_channel`)은 producer 가
  `image_ref` 를 내고 미룬 이미지를 다시 투영하는 IC5d 에서 켰다.
- 주 MRSH 소켓에는 어떤 단계에서도 fd 를 붙이지 않는다. 주 파이프라인의 버림·복구 경로를 이미지 때문에 고치는 변경은 계약 위반이다.
- 새 닫힘 자리는 모두 이름을 단다(`tests/close_site_name_boundary.zig`). 판정자를 더하면 `check-boundaries` 전체를 돌린다.
- session host 순수 판정자는 PR CI 에서 안 도는 잡이 있으므로, 머지 전에 `gh workflow run ci.yml --ref <branch>` 로 main 전용 잡을 돌린다.

## 구현 순서

### IC1 — host 원장·세그먼트·레코드 (완료)

- `image_ref`(kind 8)·`image_seg_hwm`(kind 9) 레코드 인코딩/디코딩(`src/session/screen_stream.zig`), delta base 파서
  (`screen_snapshot.computeDelta`)가 `image_ref` 를 이전 generation 표에 넣는 것.
- 세그먼트 생성 `src/platform/macos/session_host/image_segment.zig`(`shm_open`·`ftruncate`·RO 재오픈·`shm_unlink`·복사).
- 연결 원장 `src/platform/macos/session_host/image_segment_ledger.zig`(std-only leaf — 준비/발급/반환 정확히 한 번, 상한 상수
  `image_segment_max_per_connection`·`image_segment_bytes_per_connection`·`image_segment_bytes_per_host`, 개수 상한을 실측 버퍼
  64 의 절반 이하로 comptime 잠금, 큰 한 장 우선권·「전송 불가」 분류, `image_seg_hwm` 값, latest-wins 조회).
- 판정자: `zig build test-image-channel`(check-boundaries — 원장 7·base 파서 1)·`zig build test-image-segment`(test-macos-only —
  RO fd 쓰기 매핑 거부·이름 제거·CLOEXEC·남의 이름 보존·0 B 는 세그먼트 없음)·`screen_stream` 코덱 왕복과 0/비0 짝 손상 거부.
  돌연변이 21 개(반환 경로·상태 검사·상한·hwm·코덱 검사·base 파서 갈래·RO 재오픈·unlink·복사)가 모두 RED.
- 이 단계에서 원장·세그먼트는 아직 아무 연결에도 붙지 않는다(광고가 꺼져 있어 만들 일이 없다). 원장을 연결 수명에 붙이는
  것(연결 종료·채널 상실 → `releaseAll`)은 IC2, 배치 준비물·승인 시점 송신에 붙이는 것은 IC5 다.

### IC2 — 이미지 채널 수립

host 쪽(IC2a)과 앱 쪽(IC2b)으로 나눴다. 광고가 꺼져 있어 앱이 채널을 열 일이 없으므로 host 쪽만 먼저 들어가도 제품 동작은 같다.

#### IC2a — host (완료)

- 채널 메시지 코덱 `src/platform/macos/session_host/image_channel_wire.zig`(std-only — `bind_ack`·세그먼트·release 고정 길이, 공통 8 B
  머리, release 묶음 분할, token 32 자 hex)와 token 표 `image_channel_tokens.zig`(std-only — 한 번만 쓰는 token, 주 연결당 하나,
  만료·주 연결 종료로 확보 해제, `helloAdmits`·`tokenIssuable` 자리 셈).
- `server.zig`: hello 의 `role` 을 다른 필드보다 먼저 판정해 Action `.image_channel_bind`, 종단 상태 `image_channel`, 이름 붙은 닫힘
  여덟 자리, `image_shm` 을 광고한 product hello 에만 token 발급(hello_ack 의 별도 필드 — 없으면 필드째 빠져 이전 바이트와 같다),
  hello_ack 기능 목록을 후보 표로 comptime 잠금(24 칸이 가득 차 있었다), 요청 `image_channel.abandon`.
- `connection_turn.zig`: 연결의 이미지 fd·원장, release 리더(반쪽 이어 붙이기, fd 가 붙어 오면 닫고 채널 상실), 채널 상실 시 주 연결
  유지, 연결 종료·채널 상실이 같은 정리 함수를 지나 `releaseAll` 이 정확히 한 번.
- `poll_owner.zig`: token 표·host 바이트 예산 소유, 연결당 poll fd 둘(이미지 fd 는 admission 게이트와 무관하게 읽는다), 턴이 끝난 뒤
  입양, 주 연결 종료 때 token 해제, cadence 의 token 만료. 제공 스위치 `host_offers_image_channel` 는 꺼 둔다(판정자만 켠다).
- 받은 fd 를 담는 제어 버퍼는 커널이 한 메시지에 싣는 상한(254 개) 이상이다 — 잘리면 커널이 fd 를 전부 설치하고 잘린 만큼은
  알려 주지 않아 닫을 수 없다(적대적 검증 1 회차가 64 B 버퍼로 fd 14 개부터 전부 새는 것을 실측으로 잡았다).
- 판정자: `zig build test-image-channel`(check-boundaries — 코덱 4·token 표 3 을 Debug·ReleaseFast, hello 판정 7)·
  `zig build test-image-channel-host`(test-macos-only — 실제 리스너로 입양·token 재사용 거부·채널 EOF·반쪽 release·fd 붙은 release·
  두 연결 원장 분리 반환·슬롯 경계·abandon 앞뒤 순서·만료와 drain·fd 254 개 붙은 release·게이트가 닫힌 동안의 release·제공
  스위치 배선·hello 와 함께 온 바이트 거절). 제어 버퍼는 fd 254 개를 담는 크기 아래로 comptime 잠금. 적대적 검증 회차마다 고친
  자리를 돌연변이로 다시 쟀다 — 최종 집계는 PR #4328 본문. 살아남은 것은 둘이다: 닫히는 중인 주 연결에는 입양하지 않는 검사(닫히는
  연결은 같은 턴에 정리돼 재현할 수 없는 방어 갈래), owner 가 자리 셈에 `countsAsHandshaken` 대신 다른 상태 검사를 부르는 것(슬롯
  경계 판정 시점에 `.image_channel`·`.closed` 연결을 만들 수 없다).

#### IC2b — 앱 (완료)

- 새 `src/platform/macos/session_host/client_image_channel.zig`: hello_ack 해석(`image_shm` 기능 = 제공, token 없음 = 자리 없음,
  기능 없이 온 token 은 믿지 않음, 할당 실패는 오류로 올림), `bind_ack` 대기 하위 예산(`bindDeadline` — abandon 몫 500 ms 를 남기고,
  남는 것이 없으면 채널을 열지 않는다), 채널 hello 와 `bind_ack` 수신(`open` — `connectUnixUntil` 이라 CLOEXEC·NONBLOCK·SO_NOSIGPIPE,
  정확히 8 B 만 읽는다, 실패를 거부 `ImageChannelUnavailable`(hello 뒤 EOF·형식 오류)와 `ImageChannelTimedOut`(시간 초과·연결 단계
  실패)으로 가른다),
  블로킹 경로용 단조 deadline(read timeout 과 같은 5 초), 상태 `not_negotiated`·`bound`·`unavailable`. 망가진 token 도 해석
  실패로 올린다.
- `client.zig`: 두 connect 함수(`connectMajorWithPolicy`·`connectMajorUntilWithOpsPolicy`)에 광고 여부 인자를 받고, hello_ack 뒤
  `negotiateImageChannel` 이 채널을 묶거나, 거부면 abandon 을 응답까지 읽고 시간 초과면 채널만 닫는다(deadline 경로는 주 소켓이
  아직 논블로킹일 때). 블로킹 경로의 오류 정리는 Client 소멸자 하나로 모았고, 그 과정에서 `finishHello` 가 Client 에 붙인 뒤
  실패할 때 `build_id`·`lifecycle` 을 이중 해제하던 것을 고쳤다. 지금의 호출자는
  모두 광고하지 않는다. `Client.image_channel` 필드 하나(seal 스키마·source seal·projection digest·외부 입양 스냅샷 등록, deinit 이
  닫음, 이동은 구조체째). 채널 끝의 fd 는 이 필드가, 받은 세그먼트 fd 는 IC3b 의 세그먼트 표(따로 둔 필드)가 쥔다. host 는 협상할 수
  있는 연결에만 hello_ack 기능 목록에 `image_shm` 을 싣는다(협상 기록과 같은 술어 `negotiatesImageChannel`).
- 판정자: `zig build test-image-channel-app`(test-macos-only — 가짜 host 스레드와 두 경로 모두: 묶임·CLOEXEC·논블로킹·
  SO_NOSIGPIPE(옵션을 직접 잰다 — 러너가 SIGPIPE 를 무시해 EPIPE 만으로는 못 본다)·host 가 닫은 채널에 쓰면 EPIPE·deinit 이 닫음 / 거부·`bind_ack` 형식 오류 → abandon 을 응답까지 읽고 소켓에 남은 바이트 없음 /
  `bind_ack` 지연 → abandon 없이 채널만 닫고 1.5 초 deadline 안에 반환 / abandon 왕복 실패 → 기존 오류, 누수 없음 / 자리 없음·
  미제공·미광고 / 수립 실패 오류가 connect 오류 집합에 없음(comptime) / public connect 진입점의 hello 미광고, 단위 4). 적대적 검증
  회차마다 고친 자리를 돌연변이로 다시 쟀다 — 집계는 PR 본문.

### IC3 — 앱 세그먼트 표와 해석

순수 조립기 계층(IC3a)과 앱 Client 쪽(IC3b)으로 나눴다. 조립기만 먼저 들어가도 모든 적용 자리가 `.unnegotiated` 를 넘기므로 제품
동작은 같다.

#### IC3a — 조립기의 `image_ref` 해석 (완료)

- `ScreenAssembler.applySnapshot/applyDelta` 와 `RemoteScreen.applySnapshot/applyDelta` 가 `ImageRefResolver` 를 **필수 인자**로
  받는다(`union { unnegotiated, channel: SegmentResolver }`). 적용 자리 97 곳 중 95 곳(제품·테스트·폰)이 `.unnegotiated` 를 명시하고,
  나머지 둘은 `RemoteScreen` 이 받은 resolver 를 조립기로 넘기는 자리다 — 채널 resolver 를 넘기는 것은 IC3b 의 GUI 경로다.
- `image_ref` 처리: 미협상이면 0 B 레코드까지 `MalformedRow`. 미협상·조립기 예산(`image_cap`) 초과는 화면을 바꾸기 전 preflight 에서
  거부한다. delta 에서는 base generation 대조를 resolver 호출보다 **먼저** 한다(stale delta 가 세그먼트를 소비하지 않게). 0 B 이미지는
  표를 찾지 않고 빈 이미지, 예산 초과는 매핑하지 않고 `MalformedRow`(세그먼트는 표에 남아 hwm 정리·stream 닫힘이 치운다), resolver
  가 null(비운 뒤에도 없음)이면 `MalformedRow`, 매핑 크기가 `byte_len` 과 다르면 매핑을 풀고 `MalformedRow`. resolver 의
  `OutOfMemory`(매핑 실패 같은 로컬 자원 부족)는 그대로 올린다 — `MalformedRow` 로 바꾸면 진단이 host 를 가리킨다.
- `MalformedRow` 는 GUI 적용 자리에서 연결 fail-closed(`frame_malformed`) → 재접속이다(탭은 `drainRemoteNow` 복구 목록이라 살아
  있다). 탭 하나의 resync 가 아니다.
- host 원장의 host 전체 상한(`image_segment_bytes_per_host`)이 조립기 예산(`max_reassembled_image`) 이하임을 `remote_screen.zig` 가
  comptime 으로 잠근다 — 뒤집히면 큰 이미지 하나가 재접속을 되풀이시킨다.
- 픽셀 소유: `StoredImage.unmap`(null = 조립기 allocator 힙, 아니면 resolver 가 함께 준 해제 함수). 교체·`image_remove`·snapshot
  리셋·deinit·저장 실패(OOM) 다섯 자리가 모두 소유 방식대로 푼다. 픽셀은 `[]const u8` 이 됐다(매핑은 읽기 전용이다).
- 「아직 채널을 못 비움」 갈래는 조립기에 없다 — 적용 도중 멈추면 반쯤 적용된 화면이 남으므로 caller 가 적용 **전에** 그 배치를
  큐 머리에 둔다(IC3b·IC4).
- 판정자: `zig build test-image-channel`(check-boundaries — `screen assembler image ref:` 5 개, 전용 루트
  `src/screen_assembler_test_root.zig`), `zig build test-image-channel-app`(test-macos-only — `remote screen image ref:` 1 개, 원격 화면이
  resolver 를 그대로 넘긴다). 가짜 resolver 는 testing allocator 사본을 매핑 대신 넘기고 해제 함수가 횟수를 센다 — 조립기가 매핑을
  자기 allocator 로 풀면 누수 검사는 통과해도 횟수에서 잡힌다. 메타 필드는 서로 다른 값으로 단언한다(렌더러 업로드 캐시가
  generation 을 키로 쓴다). 적대적 검증 회차마다 고친 자리를 돌연변이로 다시 쟀다 — 집계는 PR 본문.

#### IC3b — 앱 세그먼트 표·채널 리더

IC3b 도 나눴다 — Client 안에서 끝나는 표·리더·release(IC3b-1)와 GUI 적용 자리 배선(IC3b-2). IC3b-2 는 다시 resolver 를 적용
자리에 넘기는 것(IC3b-2a), 펌프와 보류(IC3b-2b-1), stream 수명·hwm 정리(IC3b-2b-2), 남은 정리(IC3b-2c)로 나눴다. 표와 배선은 광고 전에 먼저 들어가도 된다(채널이
묶일 일이 없다 — 광고가 꺼져 있다).

##### IC3b-1 — 세그먼트 표·채널 리더·release (완료)

- 새 `src/platform/macos/session_host/client_image_segments.zig`(`Table`): 고정 크기다 — 항목 `image_segment_max_per_connection`(32)
  개, 못 보낸 release 버퍼 같은 개수, 덜 받은 세그먼트 메시지 하나와 그 fd, 지금 붙은 stream(동시 상한 256)과 그 최대 id.
  - `drain`: 메시지 하나의 나머지까지만 recvmsg 한다. 첫 조각 fd 정확히 하나·이어지는 조각 fd 없음·제어 버퍼 잘림 없음이 아니면
    받은 fd 를 모두 닫고 `PeerContractViolation`. EMFILE·ENFILE 은 재시도 없이 `LocalResourceExhausted`. EOF·오류·머리 불일치는
    `ChannelLost`. 표 + 못 보낸 release 가 원장 상한에 닿았는데 더 오거나 같은 id 가 다시 오면 위반. 받은 fd 는 바로 CLOEXEC.
  - 닫힌 stream 은 집합 대신 「최대 id 이하이면서 지금 붙지 않음」(계약 §6) — `openStream`·`closeStream`. 닫힌 stream 의 세그먼트는
    받는 즉시 반환, 최대 id 보다 큰 stream 은 남긴다. 최대 id 가 오르면 그 때문에 닫힌 것이 된 stream 의 남은 항목도 반환한다 —
    응답을 못 읽은 채 들어온 stream 이 끝내 열리지 않고 지나가면 그 항목이 sweep 대상도 아닌 채 원장 자리를 영구히 쥔다.
  - `resolve(stream, ref)`: 표에서 찾아 stream·image_id·generation·byte_len 대조 → `fstat` 크기 하한 → `mmap(PROT_READ)` → fd close
    → 표에서 제거 → release 적재. 못 찾거나 어긋나면 이유를 로그로 남기고 null, 항목은 그대로. mmap 의 `OutOfMemory` 는 그대로
    올린다. 해제 함수 `unmapPixels`(`munmap`).
  - `sweep(stream, hwm)`: 그 stream 의 hwm 이하 항목 반환. `flush`: release 논블로킹 쓰기(부분 쓰기 남김, 쓰기 오류는 `ChannelLost`).
  - `dropSegments`(채널 상실 — stream 추적은 남김)·`deinit`(연결 종료).
- `client.zig`: 필드 `Client.image_segments`(heap 표의 포인터 — 채널을 열기 전에 잡고 묶이지 않으면 푼다. source seal 스키마·seal
  인코더·projection digest·외부 입양 스냅샷(주소와 지문 `Table.fingerprint` 만)·tombstone·allowlist·deinit 등록). 표를 값으로 두었던
  첫 판은 Client 를 값으로 든 external pump cleanup scratch 를 1 MiB 예산보다 17 KiB 넘겨 CI 컴파일이 깨졌다 — 표 3,928 B 가 Client
  하나와 스냅샷 사본 여럿에 실렸다. 지금 scratch 는 1,046,480 B(IC3b-1 전과 같은 여유). 표 할당 실패는 「이미지 채널 없음」(연결은
  산다). 표는 Client 소유 범위 그래프의 범위 하나다(`externalOwnerRangeCount`·`fillExternalOuterOwnerRanges`·
  `externalRangeOverlapsClient` — 바깥 상한 8→9, 전체 상한 +1, 고정 scratch 148,624→148,640 B). 공개 메서드 `pumpImageChannel`(공유 울타리 안에서 비우고 release 를 쓴다 — 채널 상실은 「이미지 채널
  없음」·주 연결 유지, host 위반은 `peer_contract_violation`, fd 고갈은 `local_resource_exhausted` 로 poison. allocator callback
  안이거나 이미 poison 된 연결이면 읽지 않는다 — 위반 뒤 표는 어긋난 자리에서 멈췄을 수 있다). 선언 ledger 넷, 공개
  receiver 목록과 울타리 증명에 등록. source seal 고정 digest 를 갱신했다.
- 채널 리더는 `state == .bound` 와 `fd >= 0` 을 함께 본다. 주 연결이 poison 되면 표의 fd 는 Client 소멸(`finishDeinitGraph`)이 닫는다.
- 판정자: `zig build test-image-channel-app`(test-macos-only) — `client image segments:` 11 개(공유 메모리가 아닌 fd(pipe·디렉터리)는 crash 없이 「없음」이고 항목 보존·실제 socketpair·공유 메모리: fd 하나·
  CLOEXEC·해석·반환 한 번·나뉜 메시지의 fd·fd 개수 위반 셋과 받은 fd 전부 닫힘·닫힌 stream 즉시 반환과 모르는 stream 보존·해석
  실패 항목 보존과 hwm 정리·원장 상한·중복 id·EOF·머리 불일치·표를 버리면 fd 가 모두 닫힘·release 쓰기 실패·매핑이 fd 보다 오래
  삶·더 큰 stream id 를 알면 열리지 않은 stream 의 항목을 반환·가장 최근 stream 도 닫히면 닫힘·채널이 찼을 때 release 가 통째로
  기다렸다 경계가 맞게 도착·지문이 쓰는 칸마다 움직이고 빈 칸은 무시), `image channel pump:` 6 개(external 모드 Client 는 펌프하지 않아 봉인 상태가 그대로, 표에 넣기와 다음 펌프의 release·
  Client 소멸이 표의 fd 를 닫음, 채널 상실은 주 연결 유지, fd 개수 위반은 poison 이고 그 뒤 펌프는 읽지 않음, 외부 입양 스냅샷이 표의
  생김·바꿔 낌·내용 변화를 잡음, generation 할당·R3 retirement·소유 범위 그래프의 alias 증명이 표를 봄). 모든 칸을 채운 Client 가
  범위 상한과 같다는 기존 판정자에 표를 더했다. `image channel connect:` 의 묶임·거부 판정자가 표가 묶일 때만 남는 것을 잰다(testing allocator 가
  누수를 잡는다). seal·projection digest 가 표의 유무·주소·변화(항목·못 보낸 release·덜 받은 메시지의 fd·붙은 stream)를 잡는다(기존
  seal 판정자에 더함). scratch 예산은 기존 comptime 단언(`client_external_pump.zig`)이 잠근다.
- 안 한 것: EMFILE 판정자 — 테스트 프로세스의 fd 상한을 내리면 같은 프로세스의 다른 판정자를 흔든다. 코드는 errno 로 가른다.
  제어 버퍼 잘림(CTRUNC) — 버퍼가 커널 상한(254 fd)을 담아 보낼 수 있는 메시지로는 만들 수 없다. 부분 쓰기의 나머지 이어 쓰기 —
  release 하나가 반쪽만 들어가는 상태를 소켓 버퍼로 재현하지 못했다(통째로 기다리는 갈래만 쟀다). 픽스처에 operation fence 가 없어
  「울타리 안에서 poison」의 중첩 shared 는 실행으로 재지 않았다(공유 울타리는 개수만 센다).

##### IC3b-2a — 적용 자리에 resolver 를 넘긴다 (완료)

- `AttachmentTransport` 에 필수 필드 둘: `image_shm_negotiated(context)`·`resolve_image(context, stream_id, ref)` — 해석은 매핑된
  픽셀 slice 만 준다. 빠진 transport 를 컴파일러가 잡는다. `maru attach`(external pump)와 테스트 transport 는 `imageNotNegotiated`·
  `noImageSegment`(§8).
- resolver ctx 는 적용 하나 동안만 사는 스택 `ImageResolveCtx{transport, stream_id}` 다 — 맨 `*Client` 를 쥐지 않는다(Client 는
  generation 노드와 함께 이동한다). thunk 가 slice 를 `client_image_segments.unmapPixels` 와 짝지어 조립기 소유로 넘긴다 — 해제
  함수를 짝짓는 자리는 이 하나다.
- 고르는 규칙: 협상한 연결(`image_channel.state != .not_negotiated` — 「이미지 채널 없음」 포함)이면 채널 resolver, 아니면
  `.unnegotiated`. 채널이 묶인 적 없는 연결은 표가 없어 빈 표처럼 「세그먼트 없음」.
- 적용 자리 다섯: `RemoteAttachment.pumpScreenInternal` 의 복구 스냅샷·snapshot·delta(live·catch-up 공용), `RemoteRuntime.attachAndAssemble`
  (legacy·generation), `initObserverReconnectCandidate`. `applyExternalLiveScreen` 은 external 경로라 `.unnegotiated` 그대로다.
- 표 변경은 Client 의 공개 메서드로만: `Client.resolveImageSegment` 가 `requireBlockingMode` 울타리를 들고(봉인된 Client 의 지문을
  바꾸지 않는다), GUI 본선은 `GenerationBatchAdapter`(live 이고 자기 stream 일 때만) → `ClientSlot.resolveAttachmentImage`(다른
  attachment 연산이 slot 을 쥐면 거부) → Client 로 간다. legacy 는 transport ctx 인 Client 로 바로 간다. 첫 snapshot 은 그 owner 가
  `.initial_snapshot` permit 을 쥔 채(owner deinit 까지) 같은 스레드에서 적용되므로, slot 은 같은 스레드의 그 permit 만 허용한다 —
  막으면 협상한 연결의 첫 snapshot 이 늘 malformed 로 닫혀 재접속을 되풀이한다(적대적 검증 1 회차 HIGH).
- 판정자(`test-image-channel-app`): `image channel wiring:` 2(협상한 transport 의 resolver 가 snapshot·delta 에서 attachment 의
  stream 으로 불리고 픽셀이 화면에 든다, 협상하지 않은 transport 는 resolver 를 부르지 않고 `frame_malformed`), `image channel
  adapter:` 1(adapter 가 live slot·자기 stream 으로만 닿는다 — 다른 stream·draining 이면 없음·항목 보존, 같은 스레드의 다른 연산·다른
  스레드의 첫 snapshot 은 거부, 실제 `.initial_snapshot` permit 아래에서는 해석), `image channel attachment:` 1(커밋된 generation
  attachment 가 협상한 연결의 첫 snapshot 에 자기 stream 의 채널 resolver 를 준다), `image channel legacy:` 1, `image channel pump:` 에
  1(울타리 든 해석 — 자기 stream·한 번·poison·표 없음). GUI 정적 라이브러리(`maru-macos-app-host-abi`)가 이 경로를 컴파일한다.
- 광고가 꺼져 있어(IC6) 지금 모든 연결은 `not_negotiated` 다 — 제품 동작은 그대로다.

##### IC3b-2b-1 — 펌프와 보류 (완료)

- `image_ref` 를 실은 배치는 적용 직전에 그 연결의 채널을 비운다 — `AttachmentTransport.prepare_image_apply`(필수 필드). 비울 수
  없는 tick(Client 울타리·slot 의 다른 attachment 연산)이면 그 배치를 적용하지 않고 큐 머리에 둔다(`PumpScreenResult.held`).
  판단은 `pending_batch_head` 를 넘기고 `accounting.admit` 하기 **전**이다 — 다음 tick 에 같은 배치를 다시 셀 때 이중 계상이 없다.
  엿보기는 배치를 빌린 view 로 레코드 머리만 훑는다(소비하지 않는다). 협상하지 않은 연결과 `image_ref` 가 없는 배치는 보지 않는다.
- `held` 를 받는 쪽: GUI 펌프(`pumpDeltaInner`)는 `idle` 과 같게(다음 tick), catch-up(`prepareCatchupStage`)은 같은 스레드에서 마감까지
  헛돌지 않고 `Busy`, external pump 는 미협상이라 닿지 않는다(오면 `retry`).
- 첫 snapshot(큐를 거치지 않는다)은 resolver 를 줄 때 채널을 먼저 비운다(`imageRefResolverAfterPump`) — 그 snapshot 의 세그먼트는
  attach 응답보다 먼저 올 수 있다. 비울 수 없어도 resolver 는 준다(맞는 세그먼트가 없으면 malformed 로 재접속).
- 유지보수 tick(`maintenanceEventTick`)의 host 당 루프가 중복 host 를 건너뛴 바로 다음에 그 host 의 채널을 한 번 펌프한다 — 화면
  배치가 없는 tick 에도 release 가 host 원장을 돌린다. `quietPumpProven` 은 `drainRemoteNow` 만 건너뛰어 이 자리와 무관하다. GUI 본선은
  `HostAdapter.pumpImageChannel` → `ClientSlot.currentPumpImageChannel`(`withCurrent` — 다른 연산 중이면 이번 tick 은 건너뜀),
  legacy 는 Client 직접.
- `Client.pumpImageChannel` 은 울타리를 못 잡으면 false 를 돌려준다(보류 판단의 근거). slot 의 해석·펌프는 같은 접근 규칙
  (`attachmentImageAccessAllowed` — 다른 연산 중이면 거부, 같은 스레드의 첫 snapshot permit 만 허용)을 쓴다.
- 판정자(`test-image-channel-app`): `image channel wiring:` 에 1(못 비우면 `held` — 머리에 남고 해석·계상 없음, 다시 펌프해도 같은
  배치, 비울 수 있게 되면 적용, `image_ref` 없는 배치는 준비를 부르지 않음 — 미협상 판정자는 준비 0 회), `image channel adapter:` 에
  바쁨·첫 snapshot permit 아래 준비와 tick 경로, `image channel attachment:` 에 첫 snapshot resolver 가 채널을 먼저 비움,
  `image channel legacy:` 에 legacy 준비가 세그먼트를 받음과 tick 배선(host 당 루프의 중복 건너뛰기 바로 다음 — 글자), `image
  channel pump:` 에 울타리면 false.
- 큐 머리가 이미 있으면 새 배치를 읽기 **전에** 그 머리를 본다 — 보류 중에 읽어 붙이면 보류가 이어지는 동안 큐가 자란다(generation 은
  registry 가 차고 legacy 는 상한이 없다). 준비는 펌프당 한 번이다.
- `held` 는 정상 상태에서 사실상 나지 않는다: 펌프는 매번 배치 읽기(`read_batch`)부터 하는데 그 경로가 같은 울타리(Client
  `requireBlockingMode`, slot 의 다른 연산)를 먼저 지나 막히면 에러로 끝난다. 보류는 그 사이(읽기 뒤·적용 전)에 울타리가 바뀌는 경우의
  안전망이다.
- 안 한 것: catch-up 의 `held → Busy` 와 GUI 펌프의 `held → idle` 은 판정자가 없다(그 경로 fixture 는 실제 attach 왕복이 필요하다).
  tick 배선은 글자로 잰다. catch-up 의 `Busy` 는 후보 준비 실패 분류(`classifyCandidatePrepareFailure`)의 else 로 가서 재시도가 아니라
  `local_invariant_violation` 으로 봉인된다 — 위 이유로 닿지 않지만, IC3b-2b-2 에서 재시도로 분류할지 정한다. 채널 위반으로 poison 한
  펌프는 true(돌았다)를 돌려준다 — 그 배치는 적용으로 가 해석 실패(`frame_malformed`)로 닫힌다(첫 poison 이유는 그대로 남는다).

##### IC3b-2b-2 — stream 수명·hwm 정리 (완료)

- **열기**: `RemoteAttachment.bindTransport` 가 transport 를 묶는 순간 그 stream 을 연다(`AttachmentTransport.open_image_stream`).
  legacy(`bindLegacyTransport`)와 generation(`commitAccepted`)이 모두 stream 이 정해진 직후·배치를 읽기 전에 이 자리를 지난다. GUI 의
  attach 는 runtime 하나씩 같은 스레드에서 요청→응답→커밋을 동기로 돌아 응답을 읽은 순서와 여는 순서가 같다. decode 와 커밋 사이의
  실패(`AgentLogFormatChanged`·metadata)는 연결을 poison 하므로 닫을 필요가 없다(표는 Client 소멸이 푼다). 울타리 때문에 열지
  못하면 무해하지 않다 — 그 stream 은 「닫힌 stream」이라 세그먼트가 받는 즉시 반환되고 `image_ref` 가 해석되지 않아 연결이
  재접속한다. 제품의 커밋 경로(generation 은 실행 연산이 끝난 뒤 커밋, legacy 는 blocking 모드)는 막히지 않음을 실제 HostAdapter
  판정자가 잰다(그 판정자는 실행을 `abortPreparedRequest` 로 흉내 낸다 — 실제 execute 경로로 바꾸는 것은 IC3b-2c).
- **닫기**: `Client.dropBufferedStream` — legacy 의 stream drop·legacy ended 처리와 generation 의 `finishActiveAttachmentDrop`
  (`tryDeinit`·`commitHostRetirementNoFail` 양쪽)이 모두 지나는 자리 — 가 이미지 표의 그 stream 도 닫는다(이벤트 검증이 poison 하기
  전에). legacy ended 는 attachment 큐 머리에 보류된 `image_ref` 배치가 있어도 닫는다 — 그 배치는 다음 펌프에서 해석 실패로 끝난다
  (legacy 에서 준비가 실패하는 일은 드물다). 닫기 전에 채널을 비우지 않는다 — 늦게 온 세그먼트는
  「최대 id 이하이면서 열려 있지 않음」이라 받는 즉시 반환된다.
- **hwm 정리**: 큐를 거친 배치(복구 스냅샷·snapshot·delta)를 적용한 **뒤**·놓기 **전**에 그 배치의 `image_seg_hwm` 중 가장 큰 값으로
  그 stream 을 정리한다(`sweep_image_segments`) — 조립기는 hwm 레코드를 건너뛴다. 적용 앞으로 옮기면 그 배치가 자기 세그먼트를 먼저
  반환해 해석이 실패한다(판정자가 정리 순간까지의 해석 횟수로 잰다). 협상하지 않은 연결과 hwm 이 없는 배치는 정리하지 않는다. 적용이
  실패하면 연결을 닫으므로 정리하지 않는다. 큐를 거치지 않는 첫 snapshot 은 정리하지 않는다 — hwm 은 연결 단위로 단조라 다음 배치가
  메운다.
- 셋 다 Client 의 울타리 든 공개 메서드(`openImageStream`·`sweepImageSegments`, 닫기는 기존 `dropBufferedStream`)로 한다. GUI 본선은
  adapter(자기 stream·live) → slot(`openAttachmentImageStream`·`sweepAttachmentImageSegments` — 같은 접근 규칙) → Client. 붙은 stream
  이 host 상한을 넘으면 host 위반이라 poison 한다.
- 판정자: `image channel wiring:` 에 1(묶으면 그 stream 이 열림, hwm 을 실은 배치를 적용하면 그 hwm 으로 정리, hwm 없으면·미협상이면
  안 함, 복구 스냅샷도 정리), `image channel pump:` 에 1(열기·hwm 정리·stream drop 의 닫기, poison 뒤에는 열지도 정리하지도 않음),
  `image channel adapter:` 에 자기 stream 만 열고 정리·slot 이 바쁘면 정리 안 함, `image channel attachment:` 에 **실제 HostAdapter 의
  커밋이 그 stream 을 열고 실제 teardown 이 닫아 남은 세그먼트를 반환**, `image channel legacy:` 에 legacy 열기·정리.

##### IC3b-2c — 남은 정리

IC3b-2c 는 둘로 나눴다 — 동작에 닿는 것과 결정(2c-1)과 진단·판정자(2c-2).

###### IC3b-2c-1 — external 모드 불변식과 세 결정 (완료)

- 불변식: `image_shm` 을 협상한 Client(채널이 묶였든 잃었든 — `imageShmNegotiated`)는 external 모드에 들어가지 않는다.
  `enterExternalModeWithOps` 가 플래그를 건드리기 전에 `error.ImageChannelNegotiated` 로 거부한다(`EnterExternalModeError` 에 더함,
  `maru attach` 의 종료 코드는 `internal`). external 모드의 펌프는 채널을 비우지 않아 release 가 끊기고 원장이 찬다. GUI 는 이 길을
  쓰지 않고 external 소비자는 광고하지 않는다. 「external 모드면 펌프가 물러선다」는 방어선 판정자는 불변식을 우회해 상태를 만든다.
- 결정 — tick 의 `held` 를 다시 깨우는가: 깨운다(변경 없음). Swift 의 frame 타이머(`startFrameLoopTicks`, 반복 `Timer`)가 창이
  없어도 매 frame `maru_macos_reconnect_product_tick` → `maintenanceEventTick` 을 부르고, 보류된 머리가 있으면
  `preflightPayloadOnlyDeinit` 가 `.busy` 라 `quietPumpProven` 이 거짓이다 — 그 owner 가 선택되는 frame 마다 다시 펌프한다(16 owner
  를 넘으면 round-robin 만큼 늦는다). host 출력이 더 없어도 멈추지 않는다.
- 결정 — catch-up 의 `held → Busy` 분류: 그대로 둔다(닿지 않는다). 전제 둘: catch-up 은 새 후보 payload 에서 돌아 시작할 때 큐
  머리가 비어 있고, 루프 안에서 `held` 가 나면 곧바로 `Busy` 로 빠진다 — 그래서 준비는 늘 `read_batch` **뒤**(방금 읽은 머리)에서
  불린다. 그 자리에서 준비만 실패하는 경우가 없다: catch-up 의 준비는 `.block` 이라(IC4b) 수신 잠금으로 실패하지 않고, adapter
  (`borrowSlot(.live)`)·slot(`active_operation_generation`·drain 콜백 — 준비 쪽이 오히려 첫 snapshot permit 만큼 느슨하다)·Client
  (`requireBlockingMode`) 울타리는 `read_batch` 와 같아 그것이 먼저 막는다(`AdminBusy`·`ConnectionClosed` 등). 두 호출 사이에는
  큐에 붙이는 것뿐이다(적대적 검증 1 회차가 대조).
- 결정 — 몸체가 망가진 `image_ref`: `MalformedRow` 로 접지 않는다(계약 §6) — 다른 레코드의 디코드 오류와 같은 규칙.
- 판정자(`test-image-channel-app`, client 22): 협상한 Client(묶임·잃음)는 `ImageChannelNegotiated` 이고 플래그를 읽지 않는다, 협상하지
  않은 Client 는 이 규칙에 걸리지 않고 전환으로 간다(첫 플래그 읽기 실패 → `FlagFailed`).

###### IC3b-2c-2 — 진단 계수와 판정자 (완료)

- 대조 계수(`src/image_reconciliation.zig`)에 이미지 채널 칸 셋:
  - 손실(경고줄 `image reconciliation:`): `drop_no_segment` — `image_ref` 를 해석하지 못함(표에 없음·메타 불일치·ENOMEM 이 아닌 매핑
    실패·크기 다름 — 그 연결은 `MalformedRow` 로 재접속). 매핑의 메모리 부족(ENOMEM)만 `image_blob` 과 같은 `drop_oom`.
  - 흐름(매 5 초 `image flow:`): `channel_refused` — 펌프·해석·stream 열기·hwm 정리가 Client 울타리(`requireBlockingMode`)나 slot 의
    접근 규칙(`attachmentImageAccessAllowed`)에서 빠짐. `held` — `image_ref` 배치가 큐 머리에 보류됨(펌프마다). 지연이지 손실이 아니라
    경고줄을 울리지 않는다 — 정상 운영에서 얼마나 나는지 실측(IC6) 전이라 경고로 두면 소음일 수 있다.
  - Client 의 네 자리는 `catch return imageChannelRefused(T, 값)` 꼴이다 — Client 울타리 판정자(B3b-S)가 `catch` 몸체에 블록이나
    Client 를 읽는 호출을 받지 않는다.
  - tick 펌프(generation `currentPumpImageChannel`·legacy `backend_api.pumpImageChannel`)는 협상한 연결만 펌프한다 — 협상하지 않은
    연결이 울타리(poison 등)에 막힐 때마다 `channel_refused` 가 오르면, 협상한 연결이 없는 지금 그 칸은 전부 소음이다(적대적 검증
    1 회차).
- 판정자:
  - 조립기: 세그먼트 없음·크기 다름은 `no_segment`(oom 아님), resolver OOM 은 `oom`(no_segment 아님).
  - 대조 계수: 거부·보류는 loss 가 아니다, 줄 길이 실측(경고 256 → 293, 흐름 106 → 169).
  - 펌프: external 모드에서 빠진 펌프는 `channel_refused` 1, 보류는 `held` 로 세고 적용은 세지 않는다, slot 이 바쁠 때 빠진 준비·해석은 2.
  - 연결 둘의 같은 segment_id 는 각 연결의 픽셀로 해석되고 한쪽 해석이 다른 쪽 표를 건드리지 않는다.
  - 채널을 잃은 연결의 늦은 `image_ref` 는 울타리 거부가 아니라 「세그먼트 없음」이다(`channel_refused` 0). 조립기가 그것을
    `MalformedRow` 로 올려 그 연결이 재접속하는 것은 IC3a·IC3b-2a 판정자가 잰다. **탭이 산다**(`drainRemoteNow` 의 `MalformedRow`
    복구)는 이 단계에서 재지 않았다 — IC3b-2c-3.
  - tick 의 길: 협상하지 않은 연결은 울타리에 막혀도 `channel_refused` 0, 협상한 연결은 1(앞 갈래).

###### IC3b-2c-3 — 스레드 재고·탭 생존 판정자, id 모르는 stream 조사 (완료)

- 스레드: 표에는 잠금이 없고, Client 의 울타리(`beginPublicMutation`)는 **공유** 진입이라 두 스레드의 겹친 진입을 막지 않는다 —
  전제는 배선이 지킨다. `tests/boundary/imports.zig` 의 「image channel table is reached only from reviewed call sites」가 표에 닿는
  메서드 이름(펌프·해석·열기·정리와 slot·adapter·tick 의 그 갈래 아홉)이 나오는 자리를 파일마다 세어(최상위 test 밖, 선언 포함)
  파일·개수·스레드로 고정한다 — client 4, client_slot 10, generation_batch_adapter 8, host_adapter 2, remote_runtime 7,
  remote_term_backend 1. 새 호출자가 생기면 빨갛다(어느 스레드인지 확인하고 올린다). 지금 자리는 모두 앱 메인(소유) 스레드다 — 유지보수
  tick(`tickReconnectProductCoordinator` 가 소유 스레드를 확인), 그 tick 이 모는 화면 펌프·관찰자 재접속 단계
  (`reconnect_product_coordinator` → `progressHostReconnectOne`), 탭을 열 때의 첫 attach. 「같은 스레드」를 런타임에 재지 않는다 — 첫
  snapshot 을 다른 스레드가 적용한 뒤 소유 스레드가 이어받는 순차 이관은 겹침이 아니다.
- 탭 생존: 「이미지 채널 없음」 연결의 늦은 `image_ref`(세그먼트 없음)는 attachment 가 그 연결을 `frame_malformed` 로 닫고
  `MalformedRow` 를 올린다(실제 펌프로 잰다, `no_segment` 1). `drainRemoteNow` 의 `GenerationGap`·`MalformedRow` 갈래는 resync 를
  요청하고 탭을 끝내지 않는다(그 갈래의 블록을 문법 자리로 찾아 `requestResync` 있음·`markPumpEnded`·`process_state`·`summary.ended`
  없음을 잰다).
- 조사 — attach 응답을 끝내 못 읽어 id 를 모르는 stream: Client 는 읽지 않은 응답을 남기면 다음 RPC 가 그 응답을 받아 상관 오류로
  연결이 끝난다(IC2b 의 abandon 응답을 끝까지 읽는 이유와 같다). 그래서 그 stream 의 세그먼트는 **다음 RPC 까지만** 원장 자리를 쥐고,
  연결이 끝나면 표가 통째로 버려진다. RPC 가 오가지 않는 유휴 연결이면 그 사이가 길 수 있다 — 원장 32 칸이 그 세그먼트로 차는지는
  광고 뒤 실측(IC6, 흐름 줄의 `held`·원장 진단)에서 본다. 구조 변경은 하지 않았다.
- 「이미지 채널 없음」 탭 notice(계약 §3.2)는 광고(IC6)와 함께 단다 — 그 전에는 협상한 연결이 없다.

### IC4 — fd 상속 방지

IC4 는 둘로 나눴다 — 울타리·헬퍼·판정자(IC4a, main 위에서 IC3b-2 와 겹치지 않는다)와 채널 수신을 그 울타리로 감싸기(IC4b — 수신
코드가 IC3b-2 스택에 있어 그 머지 뒤).

#### IC4a — fork 울타리·CLOEXEC_DEFAULT 헬퍼·판정자 (완료)

- `src/platform/macos/session_host/fork_fd_fence.zig`: 프로세스 전역 `pthread_rwlock` 하나와 `pthread_atfork`(prepare=rdlock,
  parent=unlock, child=**새로 초기화**) — fork 시스템콜 하나만 읽기 잠금이다. 자식에서 unlock 하면 fork 순간 줄 서 있던 writer(자식에
  없는 스레드)에게 소유가 넘어가 자식이 다시 fork 할 때(host 띄우기의 이중 fork) 영원히 멈춘다 — 적대적 검증으로 재현했고 판정자가
  잰다. 수신 쪽 API 는 `tryLockReceive`(메인 — 못 잡으면 그 tick 의 수신을
  건너뜀)·`lockReceive`(tick 이 없는 동기 적용 자리)·`unlockReceive`. 앱 열린 fd 상한 상향(`raiseOpenFileLimit`, host 데몬과 같은
  8192).
- 앱 세션 생성(`maru_macos_app_session_create`)이 세션을 만들기 전에 울타리를 설치하고 fd 상한을 올린다(받은 fd 가 생기기 전).
- `src/pty/macos_spawn.zig`(`maru.pty.macos_spawn`): `posix_spawn` 을 `POSIX_SPAWN_CLOEXEC_DEFAULT` 로만 부른다 — stdio 는 넘기거나
  (`addinherit_np`) `/dev/null` 로 돌리고 그 밖의 fd 는 하나도 넘기지 않는다. `runShell` 이 `system()` 을 대신한다.
- 옮긴 것: 앱 안 폴백 PTY 의 terminfo 컴파일(`system()` → `runShell`), codesign 확인(`web_osr_install` — 이미 CLOEXEC_DEFAULT 였으나
  직접 선언을 헬퍼로) 과 그 파일의 테스트.
- 판정자:
  - `tests/boundary/spawn_cloexec_axis.zig`(`boundary_scans`): `src` 전체에서 최상위 test 밖의 `posix_spawn`·`posix_spawnp`·`system`
    호출·선언을 토큰으로 센다(`posix_spawn`·`posix_spawnp`·`popen` 은 이름만으로 — 별칭·`@call` 로 못 피한다, `system` 은 `(` 와 함께,
    `@field(…, "이름")` 도) — 재고는 헬퍼 자신 1 과 `maru` CLI(`src/main.zig` — 이미지 채널을 협상하지 않는다) 4 뿐, 개수가 늘어도
    줄어도 빨갛다. 스캐너 자체 시험(호출·선언은 세고 test 몸체·주석·문자열은 안 센다)과 앱이 세션을 만들기 전에 울타리를 설치하는지
    (글자)도 같은 파일에 있다.
  - `test-image-channel-app` 에 울타리 4(writer 가 줄 선 채 fork 한 자식이 다시 fork 할 수 있다, 수신 쓰기 잠금을 쥔 동안 다른
    스레드의 **실제 fork** 가 기다린다, fork 가 읽기 쪽을 쥔 동안 메인의 try-lock 은 물러선다, fd 상한)·헬퍼 3(**실제 셸**이 CLOEXEC 가
    꺼진 부모 fd 를 못 보고 stdio 만 본다, 닫힌 stdio 는 `/dev/null` 로 채워 `system()` 처럼 뜬다, `/dev/null` stdio 와 없는 프로그램은
    `SpawnFailed`).
- fork 는 세지 않는다 — 울타리가 덮는다. 앱 안 fork 자리(폴백 PTY·host 띄우기·LSP·ssh 업로드 7·git 2·업데이트 확인·로그인 셸 환경·
  에디터 검색의 `std.process.spawn` — Zig 0.16 은 fork 로 띄운다)는 모두 atfork 를 지난다.

#### IC4b — 채널 수신을 울타리로 감싸기 (완료)

- `Client.pumpImageChannel(wait)` 가 「recvmsg + `F_SETFD`」(`Table.drain`)만 수신 잠금 안에서 한다(release 쓰기·poison 은 밖).
  `wait` 는 `fork_fd_fence.ReceiveWait` — tick 이 다시 오는 자리는 `.try_lock`(못 잡으면 false, fd 는 커널 큐에 남는다), tick 이 없는
  동기 적용 자리는 `.block`(드물고 다시 올 기회가 없어 부하에서 최악 ~181 ms 를 받아들인다, §7).
  - `.try_lock`: 유지보수 tick 펌프(generation `ClientSlot.currentPumpImageChannel`·legacy `backend_api.pumpImageChannel`)와 tick
    펌프(`pumpScreen`)의 큐 머리 보류(`headHeldForImageChannel` — 못 잡으면 IC3b-2b-1 의 보류가 그 배치를 머리에 둔다).
  - `.block`: 첫 snapshot 의 `imageRefResolverAfterPump`, 관찰자 재접속 후보의 catch-up(`pumpCatchupScreen` — 같은 스레드의 동기
    루프라 물러서면 fork 하나와 겹친 재접속이 `Busy` 로 실패한다, 적대적 검증 1 회차).
  - 그래서 `AttachmentTransport.prepare_image_apply` 가 `wait` 를 받는다(ClientSlot·generation adapter·legacy 콜백이 그대로 넘긴다).
- 소켓 생성: `client_deadline.posix_ops.socket` 이 수신 잠금 안에서 `socket()` 과 `FD_CLOEXEC` 를 함께 한다(macOS 에는 `SOCK_CLOEXEC`
  가 없다). 채널 소켓과 주 소켓(deadline 연결, 그리고 일반 연결 `connectMajor` — 적대적 검증 2 회차)이 같은 길이라 모두 덮인다 — 그 틈에 fork 한 자식이 채널 소켓을 물려받으면 앱이 닫아도 host 가 EOF 를
  못 봐 원장이 붙잡힌다(IC2b 적대적 검증 3 회차).
- Swift·ObjC spawn 재고: `tests/boundary/spawn_cloexec_axis.zig` 가 `src` 의 `.swift`·`.m`·`.mm`·`.c`·`.h` 에서 주석·문자열 밖의
  `Process`·`NSTask` 생성·메시지(`Process(`·`Process.`·`[NSTask`)와 `posix_spawn`·`posix_spawnp`·`popen`·`vfork`·`system(` 를 세어
  파일·개수·이유로 고정한다 — Mermaid 도우미 1, IME 후보 관찰 smoke 1, `chrome-lab-smoke`(별도 실행 파일) 1. 단순 타입 표기
  (`let p: Process`)는 세지 않는다. Zig 스캐너도 `vfork` 를 센다(Darwin `vfork` 는 atfork 를 부르지 않는다).
- host 는 잠그지 않는다: host 가 받는 fd 는 프로토콜 위반(release 에 붙은 fd)뿐이고 owner 스레드가 같은 함수에서 닫는다. 그 틈에 host 의
  PTY spawn(fork)이 겹치면 셸이 그 fd 를 물려받을 수 있지만 그것은 위반한 앱이 보낸 fd 이고 host 원장과 무관하다(앱의 공유 메모리를
  host 가 붙잡지 않는다). accept 한 소켓의 같은 틈도 IC 이전부터 있다 — 이 단계의 범위가 아니다.
- 판정자(`test-image-channel-app`):
  - Client: 다른 스레드가 수신 잠금을 쥔 동안 tick 펌프(`.try_lock`)는 false 이고 세그먼트는 커널 큐에 남는다, 동기 펌프(`.block`)는
    풀릴 때까지 기다린 뒤 받는다, 소켓 생성은 잠금이 풀린 뒤에 CLOEXEC 가 켜진 채 돌아온다.
  - 배선: tick 펌프의 큐 머리 보류는 `.try_lock`, catch-up 의 큐 머리와 첫 snapshot resolver 는 `.block`, 미협상 transport 는
    부르지 않는다.
  - generation adapter: tick 의 길(`currentPumpImageChannel`)은 다른 스레드가 쥔 동안 false. legacy tick 은 글자로(`.try_lock` 1·
    `pumpImageChannel(.block)` 0).
  - 잠금을 쥔 스레드는 2 초 상한으로 푼다 — 잘못 기다리는 변이가 판정자를 멈추지 않는다.
- spawn 헬퍼가 자식의 신호를 기본값으로 시작한다(`POSIX_SPAWN_SETSIGMASK` 빈 마스크·`SETSIGDEF` 전부). exec 는 부르는 스레드의
  신호 마스크와 무시 처분을 물려주어, SIGTERM 을 막은 스레드가 띄운 자식이 TERM 으로 끝나지 않았다 — 이 PR 의 CI 에서
  `web_osr_install` 의 「TERM 으로 죽인 `sleep`」 판정자가 3 번 중 2 번 2 초 안에 끝나지 않았고, 같은 꼴을 로컬 판정자로
  재현했다(같은 프로세스의 어느 판정자가 TERM 을 막거나 무시한 채 두는지는 찾지 못했다 — 판정자 순서가 샤드에서 바뀌며 드러났다).
- IC3b 의 채널 리더는 IC4b 가 들어온 뒤에만 실제 fd 를 받는다(광고가 꺼져 있으므로 그 전엔 받을 일이 없다).

### IC5 — 흐름 제어와 delta 표현

IC5 는 넷으로 나눴다 — 투영의 세그먼트 방출(IC5a, 순수 계층), 연결의 원장·채널을 투영에 잇고 승인 시점에 보내기(IC5b), 용량 사건·
큰 한 장 우선권·「전송 불가」(IC5c), host 제공 스위치(IC5d).

#### IC5a — 투영의 세그먼트 방출 (완료)

- `screen_snapshot.ProjectOptions.images: ImageEmission` — `blob`(기본, 지금의 `image_blob`) 또는 `segments: SegmentSink`. 제품
  배선(`RuntimeOps.snapshot/delta`)은 아직 `blob` 이라 동작이 바뀌지 않는다(IC5b 가 협상한 연결에 sink 를 넘긴다).
- `SegmentSink`: 투영은 OS 도 원장도 모른다 — 픽셀이 있는 이미지마다 `reserveFn(image, BatchKind)` 로 자리를 청하고(준비되면
  `segment_id`, 미루면 null — 미룸 조건과 스냅샷 예외는 sink 가 정한다), 배치의 `image_seg_hwm` 은 `hwmFn` 으로 받는다. 준비한
  세그먼트의 송신·취소 수명은 sink 가 진다. 0 B 이미지는 자리를 청하지 않고 `segment_id` 0 의 `image_ref` 다.
- sink 의 답은 셋이다(`Reservation`): `segment`(id), `deferred`, `untransmittable`(계약 §4.4 — host 전체 상한보다 큰 한 장).
- 미룸 표현(계약 §5): client 가 이전 판을 가진 이미지는 placement 를 남기고 base 에 **이전** generation 을 적는다(`DrawableImages`
  가 이미지마다 base 에 적을 판을 든다) — 다음 투영이 다시 후보로 본다. 처음 보내는 이미지는 placement 도 뺀다. 미룬 새 프레임뿐이면
  delta 가 비어 배치가 나가지 않는다. 「전송 불가」는 이전 판이 있어도 placement 를 빼고 base 에도 적지 않는다.
- IC5b 가 질 의무(적대적 검증 1 회차):
  - **투영이 어떤 오류로 끝나도** 그 투영이 청한 세그먼트를 전부 취소한다 — 배치가 생기지 않아 「배치 롤백 → 취소」에 걸리지 않는다
    (attach 가 `SnapshotTooLarge` 로 끝나면 연결은 남고 원장만 찬다). 판정자: reserve 뒤 투영 실패 → 원장 0.
  - hwm 은 같은 stream 의 아직 승인되지 않은 다른 배치가 준비한 id 를 넘지 않는다(stream 마다 준비 상태 배치가 하나면 지켜진다).
  - `reserveFn` 의 `image.pixels` 는 그 호출 동안만 유효하다(core lock 아래) — 세그먼트 복사(최대 81 MB)가 core lock 안에서 일어나는
    비용을 잰다.
- **순서 제약: IC5c 는 IC5d(스위치 켜기)보다 먼저다.** 미룸으로 delta 가 비어도 server 는 그 화면 변화 토큰을 소비한다 — 정지 화면에서
  처음 보내는 이미지가 미뤄지면 다음 화면 변화까지 다시 투영하지 않아 영영 안 뜬다. 그 재투영은 IC5c 의 용량 사건 깨우기가 맡는다.
- `image_seg_hwm`: 세그먼트 모드의 snapshot 과 비어 있지 않은 delta 에 싣는다(0 이면 안 싣는다). base(host 의 다음 diff 기준)에는
  싣지 않는다. 주 스트림 예산은 `image_ref` 레코드 크기만 본다.
- 판정자(`test-image-channel` 의 screen_snapshot 6):
  - snapshot 이 `image_blob` 대신 sink 의 id 로 `image_ref`·placement·hwm 을 싣고, 조립기가 그 세그먼트로 픽셀을 받는다;
  - 처음 보내는 이미지를 미루면 placement 도 빠지고 base 가 「가졌다」고 적지 않으며, 자리가 생기면 둘이 함께 나간다;
  - 미룬 새 프레임은 이전 판·placement 를 유지하고 base 가 이전 generation 을 적으며, 자리가 생기면 새 판이 나간다;
  - 「전송 불가」는 이전 판이 있어도 placement 를 빼고(앱의 placement 0) base 에 적지 않는다;
  - 바뀐 것이 없는 delta 는 비고(hwm 없음) 이미 보낸 판은 다시 청하지 않으며, 기본 `blob` 경로에는 `image_ref`·hwm 이 없다;
  - 「attach 뒤 움직인 모든 축이 delta 로」 전수 판정자가 `image_ref`·`image_seg_hwm` 을 「producer 미방출」 목록에서 축 표로 옮겼다
    (세그먼트 축은 판정자용 sink 와 그 resolver 로 조립기까지 간다).

#### IC5b-1 — owner 층의 세그먼트 준비·발급·취소 (완료)

IC5b 는 둘로 나눴다 — owner 층(`connection_turn.Client`, 채널·원장을 쥔 층)의 연산(IC5b-1)과 그것을 Connection 의 투영·배치 승인에
잇는 배선(IC5b-2).

- `Client.prepareImageSegment(stream, image_id, generation, pixels, snapshot)` → `ImageSegmentPrepare{segment, deferred,
  untransmittable}`:
  - 「이미지 채널 없음」(원장 없음)이면 미룸 — 세그먼트를 만들지 않는다(계약 §3.2);
  - 같은 (stream, image) 의 미반환 세그먼트가 있으면 미룸 — 스냅샷은 이 규칙에서 빠진다(§5);
  - 원장 청구(`reserve`)가 연결 개수·연결 바이트·host 바이트 상한에 걸리면 미룸, host 전체 상한 초과·레코드 길이 초과는 전송 불가;
  - 청구한 뒤 공유 메모리(`image_segment.create`)를 못 만들면 청구를 되돌리고 미룸.
- `issueImageSegments`(배치 승인 직후, §4.2): 원장 발급 → 세그먼트 메시지와 fd 하나를 `sendmsg`(SCM_RIGHTS) → host 는 fd 를 바로 닫는다.
  보내지 못하면 채널 상실(`segment_send`). 그 사이 채널을 잃었으면 fd 만 닫는다.
- `cancelImageSegments`(배치 롤백·투영 실패): 준비 상태 청구를 되돌리고 fd 를 닫는다.
- `imageSegmentsIssuedThrough`: 발급한 가장 큰 id — 배치 hwm 의 바닥값(IC5b-2 가 이 배치의 준비분과 합친다).
- 판정자(`test-image-channel-host`, 실제 리스너·채널 12 → 16):
  - 발급하면 앱 끝에 메시지와 fd 하나가 오고 그 fd 를 매핑하면 픽셀이며 host 의 fd 는 닫혔다(준비 상태에선 아무것도 안 온다);
  - 취소하면 원장·host 예산이 비고 fd 가 닫히며 채널로 아무것도 안 간다;
  - 같은 이미지 미반환은 delta 만 미루고 스냅샷은 준비, host 상한 초과는 전송 불가, 「이미지 채널 없음」 연결은 미룸;
  - 앱이 채널을 닫은 뒤 발급하면 채널만 내리고 남은 준비분 fd 도 닫으며 주 연결은 산다.

#### IC5b-2 — 투영 ↔ 세그먼트 배선 (완료)

- 층 사이 타입: 준비 세그먼트(`PreparedImageSegment`·`ImageSegmentPrepare`)는 원장 leaf(`image_segment_ledger.zig`)에 둔다 —
  Connection 층(server)과 owner 층(connection_turn)이 함께 쓴다.
- `ImageChannelOps` 에 선택 필드 넷(`prepare_segment`·`issue_segments`·`cancel_segments`·`issued_through`) — owner 층이 채운다.
  `RuntimeOps` 에 선택 필드 둘(`snapshot_with_images`·`delta_with_images`) — runtime_manager 가 채운다(테스트 가짜 74 개는 그대로).
- 형식 선택(`Connection.imageSegmentOps`): `image_shm` 을 **협상**했고 세그먼트 연산이 있으면 세그먼트 판으로 투영한다 — 채널 유무가
  아니라 협상으로 고르므로 「이미지 채널 없음」 연결에도 `image_blob` 이 다시 나가지 않는다(owner 층이 미룸으로 답한다, 계약 §3.2).
  협상하지 않은 연결·제품이 아닌 attach 는 지금의 `image_blob` 이다.
- 준비분은 그 투영의 배치(`CollectedOutput.prepared_segments`)가 든다 — `commit`(배치가 큐에 승인된 같은 턴)이 발급하고 `rollback`
  이 취소한다. collect·attach 의 모든 실패 길이 `rollback` 을 지나므로(오류는 `errdefer`) **투영이 자리를 청한 뒤 실패해도** 취소된다
  (IC5a 적대적 검증 1 회차의 의무). 배치가 준비분을 들 수 없으면(OOM) 그 자리에서 취소한다.
- hwm(`CollectSegmentSink.hwm`): 그 연결이 발급한 가장 큰 id 와 이 배치가 준비한 가장 큰 id 중 큰 쪽. owner 는 연결당 한 턴에 배치
  하나를 만들고 바로 commit·rollback 하므로 같은 stream 의 승인 안 된 다른 배치가 없다 — hwm 이 남의 준비분을 넘지 않는다.
- runtime_manager: `snapshotOp`·`deltaOp` 가 이미지 방식을 받고(`.blob` 판·세그먼트 판이 얇게 감싼다), 세그먼트 판은 연결 층 sink 를
  투영 sink 로 잇는다(`ProjectionSegmentSink`). `deltaOp` 의 본문 글자(세대 판정 판정자)는 그대로다.
- 판정자(`test-image-channel` 의 server 11 — hello·abandon 7 + 배선 4):
  - 협상한 연결의 delta 는 세그먼트 판으로 투영되고(평 delta 는 안 부른다) 준비분은 commit 이 발급·rollback 이 취소한다, hwm 은
    준비분을 보고(1) 발급분과 준비분 중 큰 쪽이며(2) 이번 배치가 아무것도 준비하지 않아도 발급분을 싣는다(1);
  - 투영이 자리를 청한 뒤 실패하면 준비분이 취소되고, resync 스냅샷은 스냅샷으로 청한다;
  - 미룸·전송 불가는 아무것도 준비하지 않고, 광고하지 않은 연결은 세그먼트 판도 owner 연산도 부르지 않는다;
  - 제품 attach 의 첫 snapshot 이 세그먼트 판(스냅샷으로)이고 준비분을 attach 배치가 들며, 그 배치의 rollback 이 취소한다.
  - 판정자가 실제 결함 하나를 잡았다 — 준비분 목록 해제가 `defer` 뒤 필드 재설정으로 새던 것.
- 판정자 글자 닻 둘을 옮겼다(`session_host_screen_change_token_boundary`·`session_host_reconnect_observer_attach_boundary` — delta 투영이
  연결 헬퍼 `projectDelta` 를 거친다, 의도는 「토큰을 읽은 뒤 다음 순번으로 투영」 그대로). 헬퍼가 그 순번을 두 판 모두에 그대로
  넘기는지도 잰다.
- 적대적 검증 1 회차(IC5b-1·2 함께, HIGH 0): 준비분이 모든 경로에서 정확히 한 번 끝나고 「채널이 먼저」가 지켜짐을 대조했다. 고친 것:
  - 실제 배선 자리(owner 가 Connection 에 건넨 연산 넷, runtime 다리의 인자 대응·제품 RuntimeOps 의 두 판)를 재는 판정자가 없었다 —
    owner 판정자가 연결의 ops 로 준비·발급·취소·발급 상한·delta/스냅샷 인자를 재고(`test-image-channel-host` 17), runtime 다리 판정자
    (`runtime_manager` 루트, 같은 단계)를 더했다;
  - `commit` 이 구독을 못 찾으면 세그먼트를 취소했다 — 배치는 이미 큐에 있으므로 발급한다(앱은 닫힌 stream 의 세그먼트를 바로 반환한다);
  - `sendImageSegment` 의 EINTR 재시도에 상한(8);
  - owner 판정자의 제목·주석이 재지 않는 것을 주장했다 — 연결 개수 상한 미룸을 실제로 재고, 「이미지 채널 없음」 루프가 공허하지 않게.
- **IC6 에서 잴 것**: 세그먼트 생성(shm_open·ftruncate·mmap·memcpy)이 투영의 core lock 안에서 돈다 — 큰 이미지는 그동안 PTY reader 를
  멈추고, 같은 runtime 에 붙은 연결마다·미룸 뒤 재시도마다 다시 복사한다. lock 보유 시간을 재고 필요하면 복사를 lock 밖으로 빼거나
  (runtime, image, generation) 단위로 세그먼트를 재사용한다.

#### IC5c-1 — 용량 사건이 미룬 stream 을 깨운다 (완료)

IC5c 는 둘로 나눴다 — 용량 사건 깨우기(IC5c-1, 정지 화면의 첫 이미지가 영영 안 뜨는 공백을 막는 핵심 — IC5d 앞에 필수)와 큰 한 장
우선권·「전송 불가」 진단(IC5c-2).

- 구독(`Connection.Subscription`)의 두 표시: `image_deferred`(마지막으로 commit 된 투영이 이미지를 미뤘다 — 「전송 불가」는 세지 않는다)
  와 `image_wake`(용량 사건이 깨웠다). 세그먼트 판 투영의 commit 이 `image_deferred` 를 그 투영 결과로 바꾸고 `image_wake` 를 내린다.
  롤백은 `image_wake` 를 남긴다(압력 롤백 뒤에도 다시 시도한다, 계약 §5).
- 「화면 변화 없음」 게이트(`screen_changed`)는 `image_wake` 면 열린다 — 화면이 그대로여도 다시 투영해 미룬 이미지가 이번엔 자리를
  얻는다.
- 용량 사건 둘: release 가 원장에서 실제로 반환했을 때(`imageReadReady` — 모르는 id 는 깨우지 않는다), 채널이 묶였을 때
  (`bindImageChannel` — 「이미지 채널 없음」 동안 attach 해 미룬 stream). `Connection.noteImageCapacity` 가 미룬 stream 을 깨우고, 깨운
  것이 있으면 owner 가 그 연결의 producer 를 바로 예약한다(`scheduleImageCapacityWake` — admission 게이트가 닫혔으면 업그레이드 drain
  중일 때만).
- 판정자: server(`test-image-channel` 12) — 미룬 투영이 「미룸」을 남기고 화면이 그대로면 게이트가 막는다, 용량 사건이 깨우면 화면이
  그대로여도 투영하고 롤백은 깨움을 남기며 보낸 commit 이 두 표시를 내린다, 깨울 것이 없으면 아무것도 예약하지 않고 「전송 불가」는
  깨우지 않는다; owner(`test-image-channel-host` 18) — 채널 묶임이 깨우고 owner 가 그 깨움을 꺼내 예약하며, 모르는 id 의 release 는
  깨우지 않고 반환한 release 는 깨운다. 변이 7 RED.

#### IC5c-2 — 큰 한 장 우선권·「전송 불가」 진단 (완료)

- 우선권(`Connection.image_priority`, 계약 §4.4)은 Connection 층이 든다 — stream·commit·detach 경계를 아는 층이다. owner 층의 원장은
  그대로 「연결 상한보다 큰 한 장은 원장이 비었을 때만」을 지킨다(IC1).
  - 쥐기: 연결 바이트 상한보다 큰 이미지가 **원장이 찬 채** 미뤄지면 그 (stream, image) 가 쥔다(owner 연산 `outstanding_segments`).
    원장이 빈 채 미뤘으면(공유 메모리 생성 실패·host 상한·채널 없음) 쥐지 않는다 — 이 연결의 반환이 다시 오지 않아 쥐고 있으면
    남을 다음 화면 변화까지 막는다. 이미 다른 한 장이 쥐었으면 그 차례 뒤다.
  - 막기: 쥔 동안 이 연결의 다른 이미지는 owner 에 청하지도 않고 미룬다 — 다른 stream·스냅샷도, 같은 투영에서 앞에 오는 이미지도
    (「배치 안에서도 먼저 평가」가 이렇게 성립한다). host 전체 상한보다 큰 것은 그대로 「전송 불가」로 분류한다.
  - 놓기: 그 stream 투영의 commit 이 그 한 장을 준비했으면 놓는다(곧 발급되어 원장이 연결 상한을 넘으니 그 반환이 다른 이미지를
    깨운다). 더 다투지 않으면 놓고 깨운다 — 청하지 않음(사라졌다 — 지워짐·화면 밖·레코드 예산으로 건너뜀), 「전송 불가」가 됨(그
    사이 host 상한보다 커졌다), 원장이 빈 채 또 미룸. stream 이 떠나도(`removeAttachment` — detach·attach 롤백·RuntimeNotFound) 놓고
    깨운다. 롤백은 아무것도 바꾸지 않는다. stream id 는 연결 안에서 재사용하지 않는다.
  - 놓으며 깨운 stream 은 다음 cadence(≤ 20 ms)가 투영한다 — Connection 층은 owner 의 즉시 예약에 닿지 않는다.
  - 쥔 동안 release 는 원장이 빌 때만 깨운다 — 그 전엔 그 한 장도 못 들어가고 다른 이미지는 막혀, 깨워 봐야 투영만 헛돈다.
- 「전송 불가」 진단(`session host image untransmittable:` — slot·stream·image·generation·bytes·host 상한): host 상한 초과와 레코드
  길이(u32) 초과 두 자리 모두 `Client.imageUntransmittable` 을 지난다. u32 자리는 투영(`screen_snapshot`)이 먼저 그 이미지를
  건너뛰어 제품에선 닿지 않는 방어선이다 — 투영 쪽 건너뜀은 진단을 남기지 않는다. 그 이미지는 base 에 적히지 않아 투영마다 다시 청하므로
  최근 넷을 기억하는 거름(`UntransmittableMemo`, 원장 leaf)이 (stream, image, generation) 당 한 줄로 줄인다. 계약의 (image_id,
  generation) 을 stream 으로 좁혔다 — image id 는 runtime 마다 따로 센다.
- 판정자: server(`test-image-channel` 15) — 상한 안 이미지는 미뤄져도 쥐지 않고, 큰 한 장이 미뤄지면 쥐며 같은 stream 의 앞 이미지·
  다른 stream 의 스냅샷이 owner 에 청하지 않고 미루고 host 상한 초과는 「전송 불가」로 남으며, 원장이 비면 그 한 장이 먼저 들어가고
  롤백은 놓지 않으며 준비한 commit 이 놓되 깨우지 않는다; 사라진 한 장은 롤백이 놓지 않고 commit 이 놓으며 막혔던 stream(그 stream
  자신 포함)을 깨우고, detach 도 놓고 깨운다; 쥔 한 장이 「전송 불가」가 되거나 원장이 빈 채 또 미뤄지면 놓고 깨우며, 원장이 빈 채
  미뤄진 한 장은 쥐지 않는다. owner(`test-image-channel-host` 19) — 쥔 동안 원장이 남는 release 는 깨우지 않고 비우는 release 는
  깨우며, 두 「전송 불가」 자리 모두 판마다 한 번 거른다; Connection 에 건넨 `outstanding_segments` 가 원장 수를 답한다; IC5c-1 의
  깨움 판정자가 producer 예약(sweep 목록)까지 잰다. 원장 leaf(8) — 거름이 판마다 한 번이고 넘치면 가장 오래된 것부터 잊는다.
- 적대적 검증 1 회차(IC5c-1·2 함께): HIGH 1·MEDIUM 1 을 고쳤다.
  - HIGH — 쥔 한 장이 그 사이 host 상한보다 커지면(「전송 불가」) 청하기는 계속해 「다툰다」로 남아 우선권을 영영 쥐었다 — 정지
    pane 이면 그 연결의 모든 이미지가 굶는다 → 「전송 불가」는 사라짐과 같이 놓고 깨운다.
  - MEDIUM — 원장이 빈 채 미뤄진 한 장(공유 메모리 생성 실패 등)이 쥐면 이 연결의 반환이 다시 오지 않아 풀어 줄 사건이 없었다 →
    원장이 찬 채 미뤘을 때만 쥐고, 원장이 빈 채 또 미루면 놓는다.
  - LOW — IC5c-1 owner 판정자가 producer 예약을 재지 않았다(예약 줄을 지워도 초록) → sweep 목록으로 잰다. u32 자리 진단이 제품에서
    닿지 않음 → 문서에 적었다. 거름 4 칸이 다섯 개 넘는 「전송 불가」 이미지가 번갈아 오면 매번 적는다 → 각각 host 상한(256 MiB)보다
    커 동시에 다섯이 보일 일이 없어 그대로 둔다. 레코드 예산으로 건너뛴 한 장이 「사라짐」으로 놓였다 다시 쥐는 반복 → 그 stream 의
    프레임 수로 묶이는 비용이라 그대로 둔다.
- 한계: host 바이트 상한(`HostBytesFull`)으로 미룬 이미지는 **다른 연결**의 반환이 깨우지 않는다(IC5c-1 부터 그렇다 — 용량 사건은
  그 연결의 것만 본다). 우선권을 쥔 한 장이 원장이 빈 채 host 상한에 걸리면 이 연결의 다른 이미지도 다음 화면 변화까지 함께
  기다린다. 제품 GUI 는 host 당 광고하는 연결이 하나라 다른 연결이 host 예산을 쥘 일이 드물다 — 둘 이상이 되면 host 전체 반환을
  용량 사건으로 넓힌다.

#### IC5d — host 제공 스위치 (완료)

IC5a–c 가 처음 계획(producer 의 `image_ref`·`image_seg_hwm` 방출, 미룸 표현, 형식 선택, 용량 사건, 우선권, 「전송 불가」)을 층마다
판정자로 덮었다. IC5d 는 스위치를 켜고 층들을 한 줄로 잇는다.

- `host_offers_image_channel = true`. 제품 앱은 아직 광고하지 않으므로(IC6) 이 변경만으로 제품 동작은 바뀌지 않는다 — 기능
  목록의 `image_shm` 은 admin 이 아닌 제품 연결 모두에 실리지만, token 과 협상은 광고한 연결뿐이다. 제공 스위치 판정자(`poll_owner` 「제품 owner 는 제공 스위치를 그대로 따른다」)는 스위치가 켜져 있는 것까지 잰다
  (끄면 IC6 앱이 「이미지 채널 없음」으로 남아 이미지가 다시 주 스트림의 8 MiB 배치 상한에 걸린다).
- 통합 판정자(`test-image-channel-host`, 19 → 21): 실제 리스너·owner·채널·원장에 제품 투영(`screen_snapshot`)을 실제 TerminalCore
  위에서 돌리는 RuntimeOps 를 건다(제품 `RuntimeManager` 의 sink 다리와 같은 대응 — 그 대응은 runtime_manager 판정자가 잰다).
  앱 쪽은 stream chunk 를 배치로 잇고 채널 세그먼트를 매핑해 픽셀을 비교한다.
  - attach 스냅샷은 `image_ref` 와 placement 를 싣고 그 세그먼트의 픽셀이 채널로 온다;
  - 앱이 그 세그먼트를 돌려주기 전에 그린 새 프레임은 delta 에서 미뤄지고, 화면이 더 바뀌지 않으면 cadence 가 여러 번 돌아도
    **다시 투영하지 않는다**(투영 횟수로 잰다 — 미룬 stream 을 매번 다시 투영하는 회귀는 빈 delta 만 내 배치로는 안 보인다). release
    한 번에 새 판의 `image_ref` 와 그 픽셀이 온다;
  - 채널을 잃은 뒤(그 전 배치를 비운 다음) 새 이미지는 `image_blob`·placement 없이 빠지고 어느 이미지의 `image_ref` 도 나가지 않으며
    (delta 는 나간다), 주 연결은 산다;
  - abandon 한 연결의 attach 스냅샷과 delta 도 같다. 두 판정자 모두 `image_blob` 판 투영이 한 번도 불리지 않는다.
- 돌연변이 7 개 모두 RED: 스위치 끄기, release 깨움 제거, 「화면 변화 없음」 게이트가 깨움을 무시·미룬 stream 을 매번 연다,
  채널 상실·abandon 이 협상을 푼다(→ `image_blob` 재등장), commit 이 미룸 표시를 저장하지 않음.
- 적대적 검증 1 회차: HIGH 0. 제품 연결 경로(`connectMajor`·`connectFrozenGui`·`connectFrozenShutdownUntil`·`connectMajorUntilWithOps`)는
  모두 광고하지 않는다. MEDIUM 1(정지 구간 판정이 공허 — 투영 횟수로 고침), LOW 넷 고침(채널 상실 뒤 검사 조임, 해제 순서·errdefer,
  libc mmap, 주 연결 확인이 같은 parser 를 씀).
- 남는 위험: 이 머지부터 IC6 실측 전에 host 가 제공한다. side-by-side drain 으로 오래 사는 host 도 그대로 제공하므로, IC6 가 host 쪽
  결함을 찾으면 앱은 그 host 를 이름으로 가를 수 없다(기능 이름이 같다) — 그때는 기능 이름을 바꿔(예: `image_shm_v2`) 옛 host 와
  협상하지 않는다.
- 한계:
  - 「자리 없음」(슬롯 경계에서 token 없음) 연결은 통합 판정자에 없다 — 협상 유지는 server 판정자(「자리가 없어도 협상은 됐다」)가,
    세그먼트 판에서 채널 없는 연결의 미룸은 owner 판정자(「이미지 채널 없음」 연결은 미룸)가 잰다. 형식 선택은 셋이 같은 길이다
    (협상 여부만 본다).
  - 연결 바이트 상한(64 MiB)보다 큰 한 장의 굶음 방지는 통합 판정자에 없다 — 실제 core 에 64 MiB 넘는 이미지를 넣으려면 base64
    85 MB 를 파싱해야 해 판정자로는 무겁다. 우선권 판정은 server 판정자(가짜 owner)와 owner 판정자(실제 원장의 release 깨움)가 나눠
    잰다(IC5c-2).

### IC6 — 광고를 켜고 실측

IC6 는 셋으로 나눴다 — GUI 제품 연결의 광고와 external 차단(IC6a), 「이미지 채널 없음」 탭 안내(IC6b), 실측 gate(IC6c).

#### IC6a — GUI 제품 연결이 광고한다 (PR 진행 중)

- 제품 GUI 연결은 한 자리로 모이지 않는다 — `host_connect` 의 말단 셋(`tryConnect`·`tryConnectMajorKind`·`deadlineConnectAttempt`)
  을 새 탭·복원·재접속이 쓰고, 그중 둘은 inventory(`recovery_discovery`)·CLI(`attach_product_resolver`)와 함께 쓴다. 그래서
  `client_image_channel.Request` 를 제품 경로 셋에서 말단까지 인자로 꿴다:
  - 새 탭 `connectOrLaunchDetailed` → `tryConnect`(이 함수만 쓰는 말단이라 늘 광고);
  - 복원·재사용 판정·새 host·같은 build host 찾기·업그레이드 뒤 재연결 `connectExistingHost` → `.advertise`(업그레이드 스캔의
    prepare 연결만 `connectExistingHostWith(.off)` — RPC 하나 보내고 닫는다);
  - 재접속 worker `connectExistingHostUntil` → `connectDiscoveredHostProfileUntilObserved(.gui, .advertise)`;
  - inventory `connectDiscoveredHost*`·CLI `connectDiscoveredHostProfileUntil`·legacy `tryConnectMajor`·frozen N-1 → `.off`.
- 광고하는 client 진입점은 새 공개 함수 둘(`connectGuiWithImageChannel`·`connectGuiWithImageChannelUntil`) — 프로필을 `.gui` 로
  고정하고 현재 major 일 때만 광고한다. 기존 public 진입점은 그대로 `.off` 다(「public 진입점은 광고하지 않는다」 판정자 유지).
- external 차단은 두 겹이다: `host_connect` 말단은 GUI 가 아닌 프로필이면 광고 요청을 무시하고, client 의 두 정책 함수는
  GUI 가 아닌 프로필의 `.advertise` 를 소켓을 열기 전에 `ProtocolError` 로 거부한다. external 모드 거부(IC3b-2c-1)는 3 차 방어선.
- 옛 host 는 기능 목록을 「포함」으로만 본다 — 모르는 `image_shm` 은 무시되어 연결이 깨지지 않는다.
- 협상했는데 채널 없이 끝난 연결(자리 없음·거부·시간 초과·표 할당 실패)은 app.log 에 `session host image channel unavailable:`
  한 줄을, 펌프가 채널을 잃으면 `session host image channel lost:` 한 줄을 남긴다 — IC6b 의 탭 안내 전에는 이미지가 빠진 이유의
  유일한 앱 쪽 흔적이다.
- 판정자(`test-image-channel-app`):
  - `image channel host_connect:` 1(새 판정자 step) — 한 isolated manifest·endpoint 에 hello 만 읽는 peer 를 세우고, 경로마다 실제
    hello 바이트에 `image_shm` 이 있는지 센다: 새 탭·복원·재접속은 광고, inventory·CLI 둘·legacy 는 광고하지 않음, 말단에 GUI 가
    아닌 프로필과 광고 요청을 함께 넘겨도 광고하지 않음;
  - `image channel connect:` 에 1 — 새 진입점 둘이 실제로 광고해 협상하고(자리 없음 host → `unavailable`), GUI 가 아닌 프로필의
    광고 요청은 없는 경로에서도 `EndpointAbsent` 가 아니라 `ProtocolError`(연결보다 먼저).
- 돌연변이 9 개 모두 RED: 새 탭·복원·재접속 경로를 `.off`, inventory 를 `.advertise`, 말단 둘이 프로필을 무시, client 가드 둘 제거,
  GUI 진입점이 `.off`.

#### IC6b — 「이미지 채널 없음」 안내 (PR 진행 중)

- 계약 §3.2: 협상했지만 채널이 없는 연결(자리 없음·거부·시간 초과·채널 상실)이면 notice(이미지를 표시할 수 없음, 재접속 때 다시
  시도)를 띄운다. IC6a 이후 이 상태가 제품에서 처음 생긴다.
- 앱에는 탭 단위 안내 자리가 없다(모든 안내가 창 토스트 하나). 가장 가까운 선례 — observer 강등 안내(연결 상태에서 오는 비치명
  안내) — 와 같은 꼴로 한다:
  - 관측 사슬: `Client.imageChannelUnavailable`(`state == .unavailable`) → `ClientSlot.attachmentImageChannelUnavailable` →
    `HostAdapter.imageChannelUnavailable` → `RemoteRuntime.backend_api.imageChannelUnavailable`(legacy·generation 둘 다);
  - `RemoteTermBackend.maintenanceEventTick` 의 host 당 루프가 펌프 바로 다음에 그 연결을 보고, 루프 뒤 한 번 반영한다 —
    「없음」이 없다가 생긴 순간에만 안내를 올리고(매 tick 토스트가 뜨지 않는다), 채널이 돌아오면 내려가 다시 무장한다;
  - 앱 tick(`showPendingImageChannelNotice`)이 backend 의 안내를 AppSession 표시로 옮기고, 모달이 없을 때 i18n
    `app_image_channel_unavailable` 토스트를 한 번 띄운다(observer 와 같은 규율).
- 판정자: `test-image-channel-app` 의 `image channel notice:` 1(새 step — 없다가 생길 때만 한 번, 계속 없으면 안 올림, 꺼내기 전 여러
  tick 에도 남음, 채널이 돌아오면 재무장, tick 배선 순서), `image channel attachment:` 에 실제 HostAdapter 가 세 상태 중 「없음」만
  참, `image channel legacy:` 에 묶인 연결은 거짓·runtime 고리가 두 연결 모양 모두 위임, `image channel connect:` 에 자리 없음 → 참·
  미협상 → 거짓. 앱 안내(`app_session` 「이미지 채널 없음:」)는 observer 판정자와 같은 전체 app_session 묶음에서 돈다.
- 돌연변이 9 개 모두 RED.
- 한계: 안내는 창 토스트라 어느 탭(host)인지 말하지 않는다 — host 는 보통 하나다. host 가 둘이고 둘이 차례로 「없음」이 되면
  두 번째는 첫째가 회복되기 전엔 다시 알리지 않는다.

#### IC6c — 실측 gate (미착수)

- 실측 gate(2026-10-10 기준선과 같은 방법): terminal-browser 를 연 채 스크롤할 때
  - host 로그 `session host stream invalidated:` 0 줄, `resync sweep blocked` 의 반복 0,
  - xctrace `runloop-events` 로 16.7 ms 초과 반복이 브라우저를 닫은 상태(초당 0.3, 최대 19.9 ms)와 같은 수준,
  - `maru-metrics` 의 이미지 바이트가 주 스트림에서 사라짐.
- 이 gate 를 통과하기 전에는 프레임 드랍이 고쳐졌다고 보고하지 않는다.
