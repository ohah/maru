# 파싱 워커 인계 전 비용 측정

제품 소스는 바꾸지 않고 저장소 밖 사본의 syntax 테스트에 진단을 추가한다.
이 도구는 제품 worker 구현 전 인계 비용을 잰 당시 기록이다. 현재 제품의 worker·완료 설치·일반 입력 연결은 [구현 계획](../../docs/plans/editor-async-parse.md)을, 실제 표시 지연 비교는 [별도 도구](../editor-input-latency/README.md)를 따른다.

```sh
python3 tools/editor-async-parse-measure/run.py --output /tmp/new-handoff --deps /path/to/extracted-deps --fixtures /path/to/pinned-fixtures
python3 tools/editor-async-parse-measure/verify.py /tmp/new-handoff
python3 tools/editor-async-parse-measure/review.py /tmp/new-handoff
```

`--output`은 새 외부 경로, `--deps`는 기존 추출 의존성이다. 고정 원문은 기존 파싱 예산 실험의 다섯 파일이다.
선택적인 `--cache`는 기존 Zig 캐시를 재사용하며 결과 파일은 덮어쓰지 않는다.
macOS·mise의 Zig 0.17 및 기존 C 의존성이 필요하다. 제품 allocator를 바꾸지 않는다.

다섯 파일 × 독립 프로세스 세 개 × 반복 20회의 원시 ns를 남긴다. 스냅샷 유지, 새 parser를 포함한
Provider 복사, 워커의 본문 평탄화, 공유 Provider 해제, 마지막 Provider 해제, 마지막 스냅샷 해제를 따로 잰다.
중앙값은 정렬 후 위쪽 가운데 표본이다. 초기 파싱·스레드 생성·정확성 oracle은 각 타이머 밖이다.
워커의 cold parse와 전체 노드 종류·좌표·필드·오류 속성을 복사된 트리와 비교한다.
메인의 현재 본문이 원문과 달라지고 워커의 스냅샷은 원문과 같은지 확인한다.
스케줄러상 두 스레드가 같은 순간에 실행됐다는 증명이나 race detector 검사는 아니다.

원본 rope는 testing allocator, 워커의 별도 평탄화 배열은 page allocator를 사용한다.
워커는 원본 allocator에 접근하지 않으며 스냅샷 해제는 join 뒤 메인이 수행한다.
이 allocator 조건과 차가운 sticky summary를 포함해 해석해야 한다.
마지막 해제는 다른 참조가 없는 fixture 트리의 해제이고, 제품의 평균 퇴역 비용이 아니다.

별도 프로세스에서 바이트 변조·복사 누락·트리 좌표 변조·최신 스냅샷 오인계·메인 편집 누락을 주입하고
각각 실제 assertion 실패를 요구한다. 실패 실행의 누수 보고를 성능 모집단에 넣지 않는다.
현재 문서 revision/generation 수락·취소·종료·OOM·IME·UI 입력 지연·peak 메모리는 검증하지 않는다.
