# 고정 머리줄 변경 범위 재사용 실측

실제 선행 제품 `b42b61eb2bf4352246a22efa57f304a372fc51d8`과 변경 범위 재사용 후보를 동일 계측으로 비교했다. 원본/계측 소스·실행 파일·표본 해시와 교차 실행 순서는 외부 `sticky-change-comparison/`에 보존한다. flat-N은 함수 N개이며 함수당 4줄이다. flat-50000은 LF 200,000개와 마지막 빈 줄을 가진다.

5개 파일 × 일반/공유 입력 × 3반복 × 20입력으로 성능 실행 60개·입력 1,200개를 완료했다. 별도 정확성 실행은 20개·입력 400개이며 두 뷰를 포함한 고정 머리줄 전수 대조 600개를 완료했다. 행 번호·본문·색·출처·그려지는 행을 기준 구현과 대조하며 oracle은 시간 측정 뒤 실행한다.

단위는 ms, 선행 → 후보다. 함수 경과시간이며 GUI/HID·present·RSS 증거가 아니다. 백그라운드 부하는 완전히 통제하지 않았다.

| 표본/입력 | 전체 p50 | 전체 p95 | 전체 최대 | 고정 머리줄 p50 |
|---|---:|---:|---:|---:|
| flat-15000.zig/typing | 11.783 → 9.335 | 14.137 → 10.928 | 15.772 → 11.971 | 2.665 → 0.518 |
| flat-15000.zig/shared | 18.052 → 13.775 | 22.886 → 15.294 | 25.720 → 16.345 | 4.922 → 0.601 |
| flat-3000.zig/typing | 2.776 → 2.368 | 3.185 → 2.720 | 3.509 → 2.989 | 0.420 → 0.076 |
| flat-3000.zig/shared | 3.800 → 3.090 | 4.131 → 3.466 | 4.369 → 3.598 | 0.763 → 0.096 |
| flat-50000.zig/typing | 48.054 → 36.862 | 57.451 → 48.792 | 61.236 → 51.098 | 11.004 → 2.261 |
| flat-50000.zig/shared | 72.291 → 54.707 | 85.600 → 63.916 | 89.195 → 70.498 | 19.441 → 2.379 |
| real-build.zig/typing | 8.139 → 7.720 | 8.580 → 8.538 | 10.235 → 9.492 | 0.980 → 0.470 |
| real-build.zig/shared | 9.732 → 8.945 | 10.350 → 9.845 | 10.581 → 15.904 | 1.418 → 0.546 |
| real-host.swift/typing | 8.270 → 7.886 | 8.888 → 8.494 | 9.227 → 8.676 | 1.717 → 1.330 |
| real-host.swift/shared | 12.328 → 11.542 | 13.017 → 12.090 | 13.228 → 12.579 | 3.434 → 2.576 |

큰 합성 Zig 공유 입력의 전체 p50은 24.3% 줄었다. 모든 표본의 p50/p95는 줄었지만 real-build 공유 입력의 최대는 10.581 → 15.904ms로 증가했다. 외부 부하로 단정하거나 최악 지연 개선을 보장하지 않는다.

최대 지연 표본은 `cursor/run-0-1-real-build.zig-shared.log`의 key 12다. 같은 입력에서 전체 15.904ms, native parse 8.829041ms, Provider 편집 9.690124ms, sticky 0.550250ms, Summary 0.480041ms였다. sticky C 비교 0회·차용 2회를 확인했다. 이 같은 입력의 구간은 서로 중첩되므로 더하지 않는다. native parse가 오래 걸린 외부/내부 원인까지 확정한 증거는 아니다.

Summary의 실제 C 비교 호출은 입력당 일반 1 → 0, 공유 2 → 0이며 성공 차용은 0 → 1/2다. Provider 자신의 비교는 유지한다. 대상 뷰 자신의 이전 트리에서 얻은 범위만 사용한다.

## 검증과 재현

독립 제품 결함 5개 모두 컴파일 후 실행 단언에서 검출했으며 원본 앞뒤 대조는 통과했다. allocator 실패 순회는 Zig allocator 범위다. 데이터 손상 검증은 선행 45개·후보 48개를 거절했고 기존 schema 1/2는 각각 34/38개 손상을 거절했다. 쌍 비교의 잘못된 실행 순서·상태·경로·원본 해시 등 7개도 거절했다.

```sh
python3 tools/editor-sticky-changes/prepare.py --help
python3 tools/editor-sticky-changes/compare.py --help
python3 tools/editor-sticky-changes/summarize.py /외부/새-비교-경로
python3 tools/editor-sticky-changes/verify_pair.py /외부/새-비교-경로 --receipt /외부/검증결과.json
mise exec -- zig build test-editor-sticky-changes test-editor-sticky-symbols test-editor-fold-changes test-editor-fold-cache -j2
```

baseline 준비에는 `--baseline-ref b42b61eb2bf4352246a22efa57f304a372fc51d8`를 지정한다. 같은 입력 manifest·mode 1로 typing/shared 성능 3반복과 별도 verify 1반복을 실행한다. 기존 로그·실행 파일을 덮어쓰지 않는다. 구체 인수는 도구의 `--help`가 소유한다.

schema 3은 실제 C 호출 안쪽 계측·성공 차용 계수·별도 전체 sticky oracle을 추가한다. 자체 비교 모델 원본 15개와 차용 모델 원본 16개를 검증한다. schema 1/2의 구간·호출 수 계약은 유지한다.
