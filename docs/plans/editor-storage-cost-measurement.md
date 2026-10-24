# EW3 저장소 재구축 비용 실측

상태: EW2 머지 메인 `b627adca2`에서 비용 분리·정확성 대조 완료. 제품 최적화는 추가하지 않았다.

## 방법

`tools/editor-storage-measure/run.py`는 EW2 제품 함수 판정자를 재사용하고 저장소 밖의
private 소스 사본에만 시계를 주입한다. 제품 소스·ABI·UX·할당 실패 정책은 바꾸지 않는다.
delta(snapshot·역연산 포함), 전체 본문 복사, 줄 인덱스 생성, 뷰 줄 배열 갱신을 분리한다.
공유 게시와 후속 뷰 갱신의 줄 배열을 모두 포함하며, 단계들은 전체 시간 안의 비중이다.
구문 파싱·색칠·접힘 매핑·열 폭·보이는 줄 재구축 등은 이 네 단계 밖에 남는다.

EW2와 같은 고정 원문 5개에 일반 입력·구조 편집·붙여넣기·Undo·공유 분할을 각각 3회 실행했다.
75회 성능 실행의 855개 입력을 집계했다. 정확성은 별도 25회/285개 입력에서 키마다
버퍼와 연 문서의 본문, 각 뷰의 줄 내용, 전체 순회 접힘 결과를 대조했다.
입력 종류별 예상 byte·줄 수와 키 순서도 검사한다. 대조 비용은 성능 패스에 넣지 않는다.
시간은 unit-test 통과 조건으로 쓰지 않는다.

## 결과와 판정

| 일반 입력 | 편집+프레임 p50 | 본문 복사 p50 | 줄 인덱스 p50 | 뷰 줄 배열 p50 |
| --- | ---: | ---: | ---: | ---: |
| build.zig | 9.16 ms | 0.060 ms | 0.162 ms | 0.030 ms |
| Swift | 9.31 ms | 0.093 ms | 0.272 ms | 0.036 ms |
| 합성 Zig 3.13 MB | 48.71 ms | 0.246 ms | 1.380 ms | 0.339 ms |

기존 EW3의 1 MB에서 3~4 ms라는 값은 편집 전체의 관측이었다. 이를 본문·인덱스·줄 배열
재구축에 그대로 귀속할 수 없다. 이번 Swift 세 단계의 중앙값 합은 약 0.40 ms이고,
큰 합성 문서도 약 1.97 ms다. 각 단계 중앙값의 합은 입력별 비중의 합이나 개선 보장치가 아니다.

따라서 현재 증거로 증분 줄 인덱스나 본문 저장 방식 변경을 먼저 구현하지 않는다.
공유 뷰에는 줄 배열을 게시 후 다시 채우는 경로가 있으나, 큰 Zig 공유에서도 줄 배열 합계
중앙값은 1.680 ms이며 전체는 126.23 ms다. 중복 제거만으로 전체 지연을 해결한다고 볼 수 없다.
다음 판단은 큰 문서에서 남은 프레임 비용을 다시 분리·프로파일링하는 것이다.
이후 [편집·프레임 비용 귀속](editor-frame-attribution.md)을 수행했다. 해당 실측은 괄호 준비까지
완료한 다른 시작 조건이므로 이 문서의 수치와 동일 조건의 회귀 비교로 해석하지 않는다.
전체 조건은 [결과표](../../tools/editor-storage-measure/results.md)를 따른다.

## 재현과 검증

```sh
python3 tools/editor-storage-measure/run.py --output <새 외부 경로> --deps "$PWD/zig-pkg" --workloads typing,structure,paste,undo,shared --repetitions 3
python3 tools/editor-storage-measure/run.py --output <같은 경로> --deps "$PWD/zig-pkg" --resume --run-only --workloads typing,structure,paste,undo,shared --repetitions 1 --verify-each-edit 1 --prefix verify
python3 tools/editor-storage-measure/summarize.py <같은 경로>
python3 -m unittest discover -s tools/editor-storage-measure -p 'test_*.py' -v
```

집계기는 키 누락·중복, 단계 합이 전체 시간을 넘는 시간 오염, 미완료 제품 실행, 원문 해시 변경을
정상 대조군과 함께 거절하는지 검사했다. 원문·바이너리·원본과 계측 소스의 SHA-256을 보존한다.
계측 개발 중 옛 문서 값의 복사본으로 byte 수를 읽는 오류를 발견해 매 키의 현재 정본 조회로 고쳤다.
공유 게시의 줄 배열 구간 누락과 snapshot 해제를 인덱스 생성 시간에 포함한 경계도 수정했다.
최종 집계에서 `preliminary/`의 중간 실행은 제외한다.

추가 검토에서 빈 바이너리 manifest, 변경된 계측 소스, 숫자 접미 쓰레기 문자가 기존 집계기를
통과하는 것을 재현했다. 제품 mode 1 바이너리의 존재와 계측 소스 해시를 필수로 검사하고,
기록의 숫자는 행 끝까지 온전해야 받아들이도록 수정했다. Undo 후 예상 byte 수 오염과
별도로 계산한 p50/p95·ns→ms 변환도 대조했다. 수정 전 세 결함이 검출되지 않는 것을 확인했고,
수정 후 정상 대조군을 포함한 10개 검사가 통과했다. 실제 75회 집계 수치는 수정 전후 동일했다.

로컬 증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/editor-storage-measure/`의
`inputs.json`, `binaries.json`, `setup-1.json`, `hardware.json`, `storage-summary.json`과
`run-*.log`, `verify-*.log`다. 일반 뷰는 800×600, 공유 뷰는 각각 400×600이다.
같은 기계의 다른 부하는 통제하지 않았고 test allocator·관측 시계 비용을 포함한다.
물리 IME·AppKit 전면 입력·HID·compositor present·RSS 개선을 입증하는 실험은 아니다.
