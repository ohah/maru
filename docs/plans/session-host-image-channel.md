# Session host 이미지 채널 구현 계획

[Session host 이미지 채널](../session-host-image-channel.md)이 계약의 단일 출처다. 이 문서는 그 계약을 어떤 순서로 현실로 만드는지와
각 단계의 상태·판정자를 소유한다. 계약을 바꿔야 하면 이 문서가 아니라 계약 문서를 먼저 고친다.

## 범위와 불변식

- 모든 단계는 `image_shm` 광고 플래그가 **꺼진 채** 머지할 수 있어야 한다. 광고를 켜는 것은 IC6 하나다 — 그 전까지 제품 동작은
  지금의 `image_blob` 그대로다.
- 주 MRSH 소켓에는 어떤 단계에서도 fd 를 붙이지 않는다. 주 파이프라인의 버림·복구 경로를 이미지 때문에 고치는 변경은 계약 위반이다.
- 새 닫힘 자리는 모두 이름을 단다(`tests/close_site_name_boundary.zig`). 판정자를 더하면 `check-boundaries` 전체를 돌린다.
- session host 순수 판정자는 PR CI 에서 안 도는 잡이 있으므로, 머지 전에 `gh workflow run ci.yml --ref <branch>` 로 main 전용 잡을 돌린다.

## 구현 순서

### IC1 — host 원장·세그먼트·레코드 (미착수)

- `image_ref`·`image_seg_hwm` 레코드 인코딩/디코딩(`screen_stream`), base 파서가 `image_ref` 를 이전 generation 표에 넣는 것.
- 세그먼트 생성(`shm_open`·`ftruncate`·RO 재오픈·`shm_unlink`·복사)과 연결 원장(준비/발급/반환 정확히 한 번, 상한 상수
  `image_segment_max_per_connection`·`image_segment_bytes_per_connection`·`image_segment_bytes_per_host`, 개수 상한 comptime 잠금).
- 판정자: 원장 반환 경로 전수(준비 취소·release·연결 종료·채널 상실)의 정확히-한-번, 모르는/중복 id 무시, RO fd 쓰기 매핑 거부,
  메타 전용 레코드는 세그먼트 없음. 돌연변이로 각 반환 경로를 지워 빨개지는지 확인한다.

### IC2 — 이미지 채널 수립 (미착수)

- host: hello 의 `role:"image_channel"` 판정(`Connection.handleHello` → Action), 종단 상태, Owner 층 지연 입양과 token 표, 채널 자리
  확보 카운터와 hello 집행, token 만료, `image_channel_abandon`, 채널 상실 시 주 연결 유지, reactor 의 연결당 fd 둘, hello_ack 기능
  배열 확대와 comptime 잠금.
- 앱: 두 connect 함수의 `bind_ack` 대기(`connectUnixUntil`·절대 deadline), `ImageChannelUnavailable` → 「이미지 채널 없음」 반환.
- 판정자: `ImageChannelUnavailable` 이 spawn·업그레이드·unreachable·재접속 실패 판정으로 흐르지 않는다; 슬롯이 꽉 찬 경계에서
  token 이 안 나간다; abandon 뒤 늦은 입양이 주 연결을 닫지 않는다; peer 가 닫힌 뒤 release write 가 EPIPE 를 돌려준다(프로세스 생존);
  `destroyAll`·업그레이드 handoff 가 확보 카운터와 무관하게 진행된다.

### IC3 — 앱 세그먼트 표와 해석 (미착수)

- `Client` 필드: 이미지 채널 fd·세그먼트 표·닫힌 stream 집합(이동·allowlist·digest 등록).
- 채널 리더(메시지당 fd 정확히 하나 검사·EMFILE 감지), resolver 를 `RemoteScreen.applySnapshot/applyDelta` 필수 인자로, 해석 결과
  세 갈래, `image_seg_hwm` 정리, 닫힌 stream 처리, release 송신, 조립기 픽셀 소유 `{heap, mapping}` 과 주입 해제.
- 판정자: 버려진 배치가 남긴 세그먼트를 같은 stream 의 다음 배치가 치운다; detach 뒤 늦게 온 세그먼트가 즉시 반환된다; 연결 둘의
  같은 segment_id 가 섞이지 않는다; 미협상 resolver 가 `image_ref` 를 malformed 로 거부한다.

### IC4 — fd 상속 방지 (미착수)

- 전역 rwlock·`pthread_atfork`, `POSIX_SPAWN_CLOEXEC_DEFAULT` spawn 헬퍼와 헬퍼 밖 `posix_spawn`·`system` 을 막는 문법 자리 판정자,
  메인의 `trywrlock`·동기 적용 자리의 블로킹 잠금, 앱 `RLIMIT_NOFILE` 상향.
- IC3 의 채널 리더는 IC4 가 들어온 뒤에만 실제 fd 를 받는다(광고가 꺼져 있으므로 그 전엔 받을 일이 없다).
- 판정자: fork 와 「recvmsg + F_SETFD」 의 직렬화, 헬퍼 밖 spawn 금지.

### IC5 — 흐름 제어와 delta 표현 (미착수)

- 미룸 조건, 옛 generation 유지·첫 이미지 placement 빼기, 「보낸 표」 갱신 규칙, 스냅샷 예외, 용량 사건 깨우기 플래그, 큰 한 장 우선권,
  「전송 불가」 진단.
- 판정자: 미룬 이미지가 있는 정지 화면이 release 뒤에 이미지를 받는다; 미룬 첫 이미지 때문에 앱이 malformed 로 resync 하지 않는다;
  같은 이미지의 새 프레임이 미반환 동안 최신 하나로 모인다; 연결 바이트 상한보다 큰 한 장이 다른 이미지에 밀려 굶지 않는다.

### IC6 — 광고를 켜고 실측 (미착수)

- GUI 제품 connect 경로에서 `image_shm` 광고 플래그를 켠다.
- 실측 gate(2026-10-10 기준선과 같은 방법): terminal-browser 를 연 채 스크롤할 때
  - host 로그 `session host stream invalidated:` 0 줄, `resync sweep blocked` 의 반복 0,
  - xctrace `runloop-events` 로 16.7 ms 초과 반복이 브라우저를 닫은 상태(초당 0.3, 최대 19.9 ms)와 같은 수준,
  - `maru-metrics` 의 이미지 바이트가 주 스트림에서 사라짐.
- 이 gate 를 통과하기 전에는 프레임 드랍이 고쳐졌다고 보고하지 않는다.
