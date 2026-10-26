# 프로젝트 검색 첫 Tab 전달 진단

상태: #4597 머지 후 관측 도구·독립 검사 구현. 냉간 실행 20회 통과, 과거 중단 원인은 미확정.

## 보존할 계약

제품 Tab 순서(검색어→바꾸기→포함→제외), IME 후보 키 소비와 PID·입력 소스·포커스 검사를 유지한다.
relay의 post 완료는 앱의 이벤트 처리 완료와 다르므로 고정 대기 시간만 늘려 통과시키지 않는다.
앱과 키 입력은 기존 격리 fixture만 사용하며 일반 사용자 입력을 수집하지 않는다.

## 조사 순서

1. 기존 실패 transcript와 relay ack를 보존한다. 현재 증거는 event post와 필드의 한 시점만 있어
   이벤트 전달 지연·AppKit 소비·제품 처리 이후 필드 유지 중 어느 원인인지 확정하지 않는다.
2. private source copy에 요청 ID로 태그한 Tab의 앱 진입·view keyDown 진입/종료·keyUp을 기록한다.
   실제 물리 keycode와 OS IME 경로는 그대로 두고 Unicode 주입·키 재전송·자동 재활성화는 추가하지 않는다.
3. 냉간 실행과 연속 실행을 비교한다. 필요하면 OS 전달/앱 처리 관측을 의도적으로 지연한 대조군과
   누락·다른 ID·중복·역순·포커스/세대 불일치 음성 대조군을 포함한다.
4. 원인을 입증한 뒤 해당 경계만 수정한다. 독립 20개 이상 적대적 조건과 실제 입력을 확인하고
   PNG/OCR 전체 성공 여부를 짧은 Tab 진단 성공과 구분한다.

PNG·로그·빌드는 저장소 밖에 두며 기존 검증 앱을 덮어쓰지 않는다. 조사용 앱은 화면 기록이 필요 없는
진단 모드부터 사용하고, 제품 동작 또는 전체 캡처 경로가 바뀔 때만 최종 GUI 증거를 다시 만든다.

## 관측 결과와 도구

첫 조사 앱의 냉간 실행 15회에서 실제 Tab의 앱 진입→view keyDown 진입→처리 완료→keyUp을
요청 ID로 연결했다. 최대 앱 진입 지연은 약 7ms였고 모두 0→3 필드 이동을 확인했다.
과거 실패 실행 둘에는 view keyDown 로그가 없지만 앱 진입 관측이 없어 유실과 다른 경로 소비를
구분할 수 없다. 이 기록만으로 과거 원인을 OS 전달 지연이나 제품 Tab 오류로 확정하지 않는다.

`prepare.py`가 private source copy에만 `tab_trace.swift.inc` 관측을 붙인다. 실제 relay는 허용된
Project Search Tab에만 요청 ID를 eventSourceUserData로 싣고 post를 완료한다. 모니터는 원래
NSEvent를 그대로 반환하고 keyDown/Up의 defer는 관측만 한다. 배포 제품 코드는 수정하지 않는다.

짧은 실행은 다음과 같다. `--output`은 새 외부 경로여야 한다. 이 명령의 성공은 첫 Tab 전달과
필드 이동만 뜻하며 후보창·한자 선택·PNG/OCR 성공을 뜻하지 않는다.

```sh
python3 tools/project-search-ime/tab_probe.py --app <private-copy 바이너리> --output <새 외부 경로>
python3 -m unittest discover -s tools/project-search-ime -p 'test_*.py'
```

`tab_delivery.py`는 relay ack만으로 성공하지 않는다. 실제 요청·OS event timestamp·PID·전면 앱·
활성/key 창·owner 세대·app/view receipt 순서·필드 이동·확정 콜백 불변·종료 시점을 대조한다.
기존 장면의 필드 이동 검사를 완화하거나 입력 키를 재전송하지 않는다. 전송 응답만 있는 조건,
누락·중복·역순·다른 ID/PID/owner·비활성/외부 전면 앱·문자열 확정·시간 경계와 잘못된 숫자형 등
독립 33개 음성 대조군을 정상 대조군과 확인한다.

증거 루트는 저장소 밖 `maru-project-search-tab-20261026`이다. `tab-trace.jsonl`과 `tab-final.json`은
실제 수신과 처리 관측이며 `hid-ack.json`은 post 완료 증거다. 과거 원인은 미확정으로 남겨 두며,
다음 동일 실패는 이 둘을 대조해 전달 미관측과 처리 후 필드 유지로 구분한다.

첫 조사 앱의 15회와 최종 준비 코드에 맞춘 앱의 5회 모두 수신 관측을 통과했다. 최종 5회는
`tab_probe.py` 명령과 별도 `delivery-check.json`까지 확인했다. 이 반복 자체를 33개 적대적
조건에 합산하지 않는다. 두 실행군의 앱 fingerprint와 준비 코드의 차이는 외부 manifest에 남긴다.

최종 고정 진단 앱에서 일반 바꾸기 전체 장면도 후보 취소 5회·한자 확정·검색/파일 불변·
터미널 복귀·입력 소스 복원을 통과했다. 짧은 모드의 성공 조건으로 전체 장면을 대신하지 않는다.
