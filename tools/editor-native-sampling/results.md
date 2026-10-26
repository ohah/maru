# Native 내부 비용 샘플링 결과

측정 대상은 `54aacc5b73e8eb13638f4a9cd516af2ea2cf79e2`의 제품이다.
후속 리베이스 `aa4d1fbb8`는 새 측정 대상이 아니다. 두 커밋 사이의 syntax·편집기 모델·계측 도구와 의존성 고정 파일은 같고, 상위 변경은 LSP 테스트 연결이다.

## 모집단과 시간

기준 성능은 30프로세스·600입력, 별도 정확성은 10프로세스·200입력이다.
프로파일러를 붙인 실행은 별도 30프로세스·600입력이다. 준비 실행을 제외하며,
각 원문/입력 방식마다 독립 프로세스 세 개에서 문서 중간에 공백 20개를 삽입한다.
Zig 네 원문(생성 세 크기·실제 build.zig)과 Swift 호스트 원문을 사용했다.
아래 시간은 프로파일러 없는 기준 실행의 원시 로그다. 단위는 ms이며 각 행은 60입력이다.

| 원문/입력 | 전체 p50 | 전체 p95 | 전체 최대 | native parse p50 | changed ranges p50 |
|---|---:|---:|---:|---:|---:|
| flat-15000.zig/shared | 10.749 | 12.814 | 13.335 | 4.246 | 2.164 |
| flat-15000.zig/typing | 9.584 | 10.811 | 23.750 | 4.054 | 2.174 |
| flat-3000.zig/shared | 1.896 | 1.984 | 2.668 | 0.559 | 0.316 |
| flat-3000.zig/typing | 1.942 | 2.092 | 2.308 | 0.559 | 0.314 |
| flat-50000.zig/shared | 44.130 | 47.667 | 48.882 | 19.289 | 8.453 |
| flat-50000.zig/typing | 37.306 | 44.096 | 45.310 | 19.550 | 8.359 |
| real-build.zig/shared | 5.815 | 6.339 | 7.177 | 2.879 | 0.499 |
| real-build.zig/typing | 6.603 | 7.010 | 7.301 | 2.979 | 0.509 |
| real-host.swift/shared | 8.351 | 8.609 | 9.723 | 0.776 | 0.343 |
| real-host.swift/typing | 6.479 | 6.964 | 7.396 | 0.736 | 0.343 |

중첩한 구간의 중앙값을 더해 전체 시간을 재구성하지 않는다.

## 실제 스택 관측

전체 16,983행 중 스택 16,901행, 스택 누락 82행이다.
미해결 주소를 포함한 행은 125개, 이미지 연결을 주소로 복원한 행은 75개다.
실제 편집 진입점이 확인된 행은 5,374개다. 부분집합은 겹칠 수 있다.

다음은 편집 문맥이 확인된 표본의 self weight다. 세 프로세스를 합쳤으며
정확한 CPU 시간·호출 횟수·노드 수가 아니다. 포함 weight는 중첩되므로 더하지 않는다.

| 원문/입력 | 상위 함수 | self weight(ms) | 편집 self weight 비율 |
|---|---|---:|---:|
| flat-50000.zig/shared | `ts_subtree_summarize_children` | 509 | 27.28% |
| flat-50000.zig/shared | `ts_subtree_compress` | 229 | 12.27% |
| flat-50000.zig/shared | `ts_subtree_get_changed_ranges` | 221 | 11.84% |
| flat-50000.zig/shared | `iterator_descend` | 170 | 9.11% |
| flat-50000.zig/typing | `ts_subtree_summarize_children` | 489 | 25.94% |
| flat-50000.zig/typing | `ts_subtree_compress` | 240 | 12.73% |
| flat-50000.zig/typing | `ts_subtree_get_changed_ranges` | 201 | 10.66% |
| flat-50000.zig/typing | `iterator_descend` | 179 | 9.50% |
| real-host.swift/shared | `ts_parser_parse` | 17 | 18.09% |
| real-host.swift/shared | `iterator_advance` | 13 | 13.83% |
| real-host.swift/shared | `ts_subtree_summarize_children` | 10 | 10.64% |
| real-host.swift/shared | `iterator_descend` | 6 | 6.38% |

## 확인과 한계

보관 바이너리·dSYM UUID, 실제 코드 영역·load address와 전체 대상 주소를 SDK로 대조했다.
원본 trace를 SDK로 다시 내보내 시각·스레드·PID·core·상태·weight·주소 순서를 비교했다.
프로젝트 reader를 import하지 않는 독립 reader가 30개 집계와 기준 시간 90필드를 대조했다.
최종 판정기로 다섯 가설의 의미 손상 23건을 거절하고 정상/등가 대조 12개를 통과했다.
표시 이름만 바뀐 XML은 같은 자료로 인정하지만, weight와 요약을 함께 위조한 자료는 원본 trace 대조에서 거절한다.

수집 중 이미지 없는 주소·표시 이름 누락을 재현해 주소 기반 해석을 추가했다.
실행된 frame 계약을 근거 목록에서 함께 지우는 손상과 `False == 0` 때문에 잘못된 요약 타입을 인정하던 검증기 결함도 보강했다.
이것은 도구의 근거 판정 수정이며 제품 편집 결함이나 성능 개선은 아니다.

큰 Zig 문서에서는 subtree 요약·압축과 변경 범위 내부 함수가 큰 비중을 차지한다.
이 관측만으로 재사용 노드 수, 변경 범위 생략의 안전성, worker 필요성, 개선율은 확정할 수 없다.
실제 UI의 파싱 예산과 현재 기준 실행 조건을 먼저 대조한 뒤 후속 최적화를 결정한다.
GUI/HID·IME·GPU present·RSS와 모든 언어의 최악 비용은 검사하지 않았다.

## 원시 근거

저장소 밖 `~/.cache/maru-agent-artifacts/`에 다음 자료를 보존한다.
이 경로의 실측 파일은 Git/CI에 포함하지 않으며 재현 명령은 [README](README.md)에 있다.

- `native-sampling-1/baseline/`: 전체 소스·생산자·보관 바이너리·40개 로그.
- `native-sampling-4/profiles/`: dSYM·30개 원본 trace·XML·대상 로그·SDK 출력·해시.
- `native-sampling-verified-3.json`·`native-sampling-independent-final-bridge-3.json`: 최종 reader 전체 재검증과 독립 수치 연결.
- `native-sampling-adversarial-3/result.json`: 실제 의미 손상·정상/등가 대조와 원본 보존 대조.
- `native-sampling-independent-1.json`: 별도 SDK 주소 해석·원시 XML·시간 통계 대조.
- 초기 실패와 진단용 복원 XML은 보존하되 최종 30개 모집단에 섞지 않는다.
