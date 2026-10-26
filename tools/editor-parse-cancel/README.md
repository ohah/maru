# 실제 파싱 콜백의 취소·스냅샷 수명 검증

제품 실행 코드를 바꾸지 않는 독립 SDK 실험이다. [수명 검토안](../../docs/plans/editor-async-parse.md)의
논리 모델을 실제 Provider·rope 스냅샷·OS 스레드·Tree-sitter progress callback으로 대조한다.
제품 큐·wake·문서 닫기 명령·종료 처리를 구현한 것은 아니다.

```sh
python3 tools/editor-parse-cancel/run.py --output /tmp/new-parse-cancel --deps /path/to/deps --fixtures /path/to/pinned-fixtures
python3 tools/editor-parse-cancel/verify.py /tmp/new-parse-cancel
python3 tools/editor-parse-cancel/review.py /tmp/new-parse-cancel
```

새 외부 output, 기존 추출 dependencies, 앞선 파싱 예산 실험의 다섯 고정 fixture가 필요하다.
macOS·Zig 0.17·ReleaseFast 조건이며 `--cache`로 기존 Zig 캐시를 재사용할 수 있다.
제품 src·build는 Git과 일치해야 한다. 실제 소스 사본·수집기 사본·원문·실행 바이너리·원시 로그를 보존한다.
독립 verifier는 주입한 hook과 probe를 제거한 사본이 원래 제품 해시와 일치하는지도 확인한다.

## 장벽과 소유권

독립 사본의 `Provider.onProgress` 앞에 시험용 hook을 넣는다. Tree-sitter의 실제 C 호출이
이 callback에 들어오면 entered를 알리고 release를 기다린 뒤 atomic 취소 여부를 반환한다.
메인은 그동안 원본 rope를 편집·종료하고, 취소 저장소와 원본 스냅샷은 join 이후까지 유지한다.
워커는 별도 page allocator로 복사한 본문을 C에 넘기며 Provider와 본문 배열을 C 반환 후 해제한다.
원본 rope allocator는 메인만 사용한다. 이 구조는 의도적으로 C 호출을 멈추는 수명 시험이다.

한 번에 워커 하나만 실행한다. 전역 probe 포인터는 spawn 전에 설치하고 join 후 제거하며 실행 중
교체하지 않는다. 취소 상태·entered·release·done은 atomic이다. 제품의 다중 작업 취소 저장소 설계로
이 전역 포인터 방식을 채택한 것이 아니다.

## 대조군

다섯 fixture × 두 독립 프로세스 × 다섯 반복 × 아래 네 경우, 총 200경우다.
빌드 확인과 오류 주입 실행은 정상 모집단에 넣지 않는다. 한 원시 행은 네 경우를 모두 통과한 반복이다.

| 경우 | 기대 결과 |
| --- | --- |
| 첫 콜백 전에 취소 | 실제 callback은 호출되며 C 반환 후 트리 없음 |
| 콜백 진입 후 취소 | 장벽 해제 전 작업은 끝나지 않으며 C 반환 후 트리 없음 |
| 취소 없는 정상 완료 | 원문 해시와 같은 복사본을 파싱해 트리 생성 |
| 본문 복사 할당 실패 | 실제 FailingAllocator 실패, parser 생성·callback 호출 없음 |

각 경우 원본 버퍼 종료 후 붙든 스냅샷을 다시 읽어 원문과 전체 byte를 대조한다.
워커 복사본은 원문 해시와 비교한다. 실제 OOM 검증 범위는 **본문 복사 할당**이며,
C parser 내부 malloc 실패나 제품 큐 준비 실패는 주입하지 않았다.

별도 실행에서 취소 무시·정상 작업을 잘못 취소·복사본 변조·실패 allocator 우회·장벽 우회를
각각 주입해 assertion으로 거절한다. 이는 시험용 어댑터의 다섯 결함이며 제품 결함 발견 수가 아니다.
수집기는 실패를 성공으로 세지 않고 두 종류의 실제 assertion 형식을 확인한다.

## 결과와 한계

[결과](results.md)에 채택한 증거와 범위를 기록한다. 이 시험은 인위적인 장벽을 포함하므로
취소 지연·콜백 간격·성능 수치로 해석하지 않는다. C callback 저장소를 실제로 조기 free하는 위험한
결함을 주입하지 않았고, race detector·ASan 검증도 아니다. 현재 제품의 IME·Undo·공유 뷰·
결과 수락·완료 wake·종료 join은 후속 실제 서비스 검증 대상이다.
