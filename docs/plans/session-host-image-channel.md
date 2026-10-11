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
  닫음, 이동은 구조체째). 채널 끝의 fd 는 이 필드가, 받은 세그먼트 fd 는 IC3 의 세그먼트 표(따로 둔 필드)가 쥔다. host 는 협상할 수
  있는 연결에만 hello_ack 기능 목록에 `image_shm` 을 싣는다(협상 기록과 같은 술어 `negotiatesImageChannel`).
- 판정자: `zig build test-image-channel-app`(test-macos-only — 가짜 host 스레드와 두 경로 모두: 묶임·CLOEXEC·논블로킹·
  SO_NOSIGPIPE(옵션을 직접 잰다 — 러너가 SIGPIPE 를 무시해 EPIPE 만으로는 못 본다)·host 가 닫은 채널에 쓰면 EPIPE·deinit 이 닫음 / 거부·`bind_ack` 형식 오류 → abandon 을 응답까지 읽고 소켓에 남은 바이트 없음 /
  `bind_ack` 지연 → abandon 없이 채널만 닫고 1.5 초 deadline 안에 반환 / abandon 왕복 실패 → 기존 오류, 누수 없음 / 자리 없음·
  미제공·미광고 / 수립 실패 오류가 connect 오류 집합에 없음(comptime) / public connect 진입점의 hello 미광고, 단위 4). 적대적 검증
  회차마다 고친 자리를 돌연변이로 다시 쟀다 — 집계는 PR 본문.

### IC3 — 앱 세그먼트 표와 해석 (미착수)

- `Client` 필드: 세그먼트 표·닫힌 stream 집합(이동·allowlist·digest 등록). 채널 fd 필드는 IC2b 가 둔다.
- 채널 리더는 `state == .bound` 와 `fd >= 0` 을 함께 본다. 주 연결이 poison 되면 host 는 채널도 닫으므로(IC2a) poison 경로가 채널
  fd 를 어떻게 놓을지 정한다 — 지금은 회수 때 `finishDeinitGraph` 가 닫는다.
- 채널 리더(메시지당 fd 정확히 하나 검사·EMFILE 감지), resolver 를 `RemoteScreen.applySnapshot/applyDelta` 필수 인자로, 해석 결과
  세 갈래, `image_seg_hwm` 정리, 닫힌 stream 처리, release 송신, 조립기 픽셀 소유 `{heap, mapping}` 과 주입 해제.
- 판정자: 버려진 배치가 남긴 세그먼트를 같은 stream 의 다음 배치가 치운다; detach 뒤 늦게 온 세그먼트가 즉시 반환된다; 연결 둘의
  같은 segment_id 가 섞이지 않는다; 미협상 resolver 가 `image_ref` 를 malformed 로 거부한다.

### IC4 — fd 상속 방지 (미착수)

- 전역 rwlock·`pthread_atfork`, `POSIX_SPAWN_CLOEXEC_DEFAULT` spawn 헬퍼와 헬퍼 밖 `posix_spawn`·`system` 을 막는 문법 자리 판정자,
  메인의 `trywrlock`·동기 적용 자리의 블로킹 잠금, 앱 `RLIMIT_NOFILE` 상향.
- IC3 의 채널 리더는 IC4 가 들어온 뒤에만 실제 fd 를 받는다(광고가 꺼져 있으므로 그 전엔 받을 일이 없다).
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
