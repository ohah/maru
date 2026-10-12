# Session host 이미지 채널 구현 계획

[Session host 이미지 채널](../session-host-image-channel.md)이 계약의 단일 출처다. 이 문서는 그 계약을 어떤 순서로 현실로 만드는지와
각 단계의 상태·판정자를 소유한다. 계약을 바꿔야 하면 이 문서가 아니라 계약 문서를 먼저 고친다.

## 범위와 불변식

- 모든 단계는 `image_shm` 광고 플래그가 **꺼진 채** 머지할 수 있어야 한다. 앱이 광고를 켜는 것은 IC6 하나다 — 그 전까지 제품
  동작은 지금의 `image_blob` 그대로다. host 의 제공(hello_ack 의 `image_shm`·token, `host_offers_image_channel`)은 producer 가
  `image_ref` 를 내기 시작하는 IC5 에서 켠다.
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
자리에 넘기는 것(IC3b-2a)과 stream 수명·펌프·hwm 정리·보류(IC3b-2b)로 나눴다. 표와 배선은 광고 전에 먼저 들어가도 된다(채널이
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

##### IC3b-2a — 적용 자리에 resolver 를 넘긴다 (PR 진행 중)

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

##### IC3b-2b — stream 수명·펌프·hwm 정리·보류 (미착수)

- **울타리를 못 잡은 해석은 지금 「세그먼트 없음」 → `MalformedRow` → 재동기화다**(IC3b-2a). prepared lease·slot 연산이 겹친 tick 에
  `image_ref` 배치를 적용하면 그렇게 된다. 「아직 채널을 못 비움·해석 불가」 보류로 막는다 — 그 배치를 적용하지 않고 큐 머리에 둔다.
  판단은 `pending_batch_head` 를 넘기고 `accounting.admit` 하기 **전에** 한다(다음 tick 에 같은 배치를 다시 셀 때 이중 계상이 없게).
- `pumpImageChannel` 을 매 tick(`RemoteTermBackend.maintenanceEventTick` 의 host 당 한 번 — `quietPumpProven` 이 건너뛰지 않게)과
  `image_ref` 배치 적용 직전에 부른다. attach 응답을 **읽는 순서대로**(호출자로 돌아간 뒤가 아니라) `openStream`, detach·종료 정리와
  attach 응답 뒤의 모든 실패 경로에서 채널을 비운 뒤 `closeStream`. 적용 뒤 배치를 놓기(`releaseOrRetain`) **전에** 그 배치에서 hwm 을
  다시 읽어 `sweep`(조립기는 hwm 을 건너뛴다). 셋 다 Client 의 울타리 든 공개 메서드로 한다(IC3b-2a 와 같은 규칙).
- 스레드: 표는 재접속 worker 가 connect 할 때 할당되고(`build_id` 와 같은 꼴) 펌프·해석·적용·정리는 모두 소유 스레드에서 돈다 — 표에
  잠금이 없다는 전제를 배선이 지키는지(worker 스레드에서 펌프·해석을 부르지 않는지) 판정자로 잰다.
- `enterExternalMode` 는 묶인 채널을 거부하지 않는다 — 협상한 Client 가 external 모드에 들어가면 펌프가 돌지 않아 원장이 찬다.
  GUI 는 이 경로를 쓰지 않지만, 광고(IC6) 전에 불변식(채널을 협상한 Client 는 external 모드에 들어가지 않는다)으로 잠근다.
- 「이미지 채널 없음」 탭 notice(계약 §3.2)는 아직 어느 단계에도 없다 — `pumpImageChannel` 이 void 라 호출자는
  `image_channel.state` 로 상실을 본다. notice 를 이 단계나 IC6 에서 단다.
- 펌프·해석이 울타리에서 빠지는 일(prepared lease·실행 lease 의 AdminBusy)은 지금 계수도 로그도 없다 — lease 가 오래 잡혀 host 원장
  32 칸이 차면 진단할 근거가 없으니 거부 계수를 단다.
- attach 응답을 끝내 못 읽어 id 를 모르는 stream 의 세그먼트는 더 큰 id 를 알 때까지(다음 attach) 표에 남아 원장 자리를 쥔다 —
  id 를 모르니 `closeStream` 으로도 못 닫는다. 그 연결이 다음 attach 없이 오래 머무는 경로가 있는지 본다.
- 채널 resolver 를 넘기는 연결에서 몸체가 망가진 `image_ref` 는 `MalformedRecord`·`Truncated` 로 올라가 `drainRemoteNow` 복구 목록에
  없다(연결은 재접속하는데 탭은 종료된다 — 다른 레코드의 디코드 오류도 지금 같다). `MalformedRow` 로 접을지 정해 계약 §6 에 적는다.
- resolver 의 OOM·거부 경로에 이미지 대조 계수(`image_reconciliation`)를 붙이거나 붙이지 않는 이유를 적는다(`image_blob` 경로는
  OOM 에 `recordDroppedOom` 을 올린다).
- 판정자: 버려진 배치가 남긴 세그먼트를 같은 stream 의 다음 배치가 치운다; detach 뒤 늦게 온 세그먼트가 즉시 반환된다(표 단위는
  IC3b-1 이 쟀다 — 여기서는 배선); 연결 둘의 같은 segment_id 가 섞이지 않는다; 다른 stream 의 세그먼트를 가리키는 `image_ref` 는
  해석되지 않고 그 항목은 남는다(표 단위는 IC3b-1); 「이미지 채널 없음」 연결의 늦은 `image_ref` 는 그 연결의 재접속으로 끝나고 탭은
  종료 상태가 되지 않는다; 울타리를 못 잡은 tick 의 `image_ref` 배치는 보류되고 다음 tick 에 적용된다.

### IC4 — fd 상속 방지 (미착수)

- 전역 rwlock·`pthread_atfork`, `POSIX_SPAWN_CLOEXEC_DEFAULT` spawn 헬퍼와 헬퍼 밖 `posix_spawn`·`system` 을 막는 문법 자리 판정자,
  메인의 `trywrlock`·동기 적용 자리의 블로킹 잠금, 앱 `RLIMIT_NOFILE` 상향.
- IC3b 의 채널 리더는 IC4 가 들어온 뒤에만 실제 fd 를 받는다(광고가 꺼져 있으므로 그 전엔 받을 일이 없다).
- 판정자: fork 와 「recvmsg + F_SETFD」 의 직렬화, 헬퍼 밖 spawn 금지.
- 앱 채널 소켓 생성도 볼 것: `connectUnixUntil` 은 `socket()` 과 CLOEXEC 설정이 별개 호출이라 그 사이 fork 한 자식이 채널 소켓을
  물려받을 수 있다(IC2b 적대적 검증 3 회차). 물려받으면 앱이 채널을 닫아도 host 가 EOF 를 못 봐 원장이 붙잡힌다 — 쓰기 잠금이 채널
  소켓 생성도 덮게 한다(주 소켓에도 원래 있는 틈이다).
- host 쪽도 볼 것: host 가 받는 fd 는 프로토콜 위반(release 에 붙은 fd)뿐이고 owner 스레드가 받자마자 닫는다. 다른 스레드가 그
  사이에 fork 하는 자리가 host 에 있는지(IC2a 적대적 검증 2 회차 메모) 확인해 같은 잠금 범위에 넣을지 정한다.

### IC5 — 흐름 제어와 delta 표현 (미착수)

- producer 가 `image_ref`·`image_seg_hwm` 을 내기 시작한다 — `screen_snapshot.zig` 의 전수 판정자(「attach 뒤 움직인 모든 축이
  delta 로 client 에 닿는다」)에서 두 종류를 「producer 미방출」 목록에서 축 표로 옮긴다(IC1 이 목록에 올려 뒀다).
- 미룸 조건, 옛 generation 유지·첫 이미지 placement 빼기, 「보낸 표」 갱신 규칙, 스냅샷 예외, 용량 사건 깨우기 플래그, 큰 한 장 우선권,
  「전송 불가」 진단. release 로 원장에 여유가 생기면 그 연결의 producer 를 바로 예약한다(계약 §3.5 — IC2a 는 release 를 읽어
  원장만 바꾼다).
- 형식 선택은 `Connection.image_shm_negotiated`(token·채널 유무와 무관, IC2a 가 기록)로 한다. 협상한 연결에 채널이 없으면 세그먼트를
  만들지 않고 placement 를 뺀다(계약 §3.2) — token 이나 채널 유무로 고르면 그 연결에 `image_blob` 이 다시 나간다. producer 는
  `server.Connection` 층이고 채널·원장은 `connection_turn.Client` 층이라, 채널 상태와 원장 reserve/cancel 을 `ImageChannelOps` 로
  넘긴다. 판정자: 자리 없음·abandon·채널 상실 뒤에도 그 연결에 `image_blob` 이 나가지 않는다.
- 이 단계에서 host 제공 스위치 `host_offers_image_channel` 를 켠다.
- 판정자: 미룬 이미지가 있는 정지 화면이 release 뒤에 이미지를 받는다; 미룬 첫 이미지 때문에 앱이 malformed 로 resync 하지 않는다;
  같은 이미지의 새 프레임이 미반환 동안 최신 하나로 모인다; 연결 바이트 상한보다 큰 한 장이 다른 이미지에 밀려 굶지 않는다.

### IC6 — 광고를 켜고 실측 (미착수)

- 이미지 채널 리더·세그먼트 표·resolver 를 설치하는 GUI 제품 호출자가 connect 함수에 `Request.advertise` 를 넘긴다(`client_kind`
  로 정하지 않는다 — `.gui` 로 붙지만 resolver 없이 조립기를 쓰는 소비자가 있다, 계약 §2). 그 호출 자리를 「public 진입점은
  광고하지 않는다」 판정자의 예외로 옮긴다.
- 실측 gate(2026-10-10 기준선과 같은 방법): terminal-browser 를 연 채 스크롤할 때
  - host 로그 `session host stream invalidated:` 0 줄, `resync sweep blocked` 의 반복 0,
  - xctrace `runloop-events` 로 16.7 ms 초과 반복이 브라우저를 닫은 상태(초당 0.3, 최대 19.9 ms)와 같은 수준,
  - `maru-metrics` 의 이미지 바이트가 주 스트림에서 사라짐.
- 이 gate 를 통과하기 전에는 프레임 드랍이 고쳐졌다고 보고하지 않는다.
