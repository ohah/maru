# 프로젝트 검색 도크 기반 검증

현재 구현은 파일별 결과 모델·입력 수명·Chrome 표시 컴포넌트까지다. **앱 검색 도크는 아직 연결하지 않았다.**
제품 계약과 단계별 완료 조건은 [프로젝트 검색 계획](editor-project-search.md)을 따른다.

## 수정한 결함

- 결과 경로 `a.zig`와 `./a.zig`가 다른 그룹으로 나뉘었다. 기존 요청의 상대 경로 검증을 적용하여 그룹 키를 통일한다.
  상위 이동·절대 경로는 받지 않으며, 실패한 행의 소유권은 호출자에게 남긴다. symlink·hard link의 서로 다른 이름은 합치지 않는다.
- 텍스트 clip이 조상 도크 영역만 따라 입력칸·버튼·결과 행의 경계를 넘었다. 자기 면과 조상 clip의 교집합을 사용한다.
  소수 좌표에서는 가까운 변을 올리고 먼 변을 내려 옆 면으로 글자가 번지지 않게 한다.
- 비활성 검색·취소 버튼을 접근성 서술자에서는 활성으로 표시했다. 동작 표와 서술자가 같은 활성 판정을 사용하며,
  비활성 글자는 흐린 색으로 그린다.
- 자동 대기 판정은 조합을 막았지만 명시적 시작 API는 이를 확인하지 않았다. `presentation.State.begin`은
  조합 상태 또는 OS 입력 transaction이 있으면 `false`를 반환하고 상태를 그대로 둔다. 실제 키 라우팅은 아직 미연결이다.
- 잘못된 scroll shift나 결과 높이 산술이 정수 변환·곱셈에서 실패할 수 있었다. build 전에 검증하여
  `InvalidGeometry`로 거부한다. 같은 행 ID가 반복되면 공통 tree의 `DuplicateIdentity`로 발행을 중단한다.

## 확인한 동작

- root·문서 owner·slot·generation·revision·composition 중 하나가 달라도 독립 그룹을 유지한다.
- 현재 요청·root·모델 신원과 다른 batch·완료, 취소·입력 변경 후 늦은 완료는 적용하지 않는다.
  완료 후 재완료·추가 행도 받아들이지 않는다. 부분 결과·실패·성공 0건은 다른 상태로 유지한다.
- 모든 행 추가·표시 인덱스 allocation 실패를 주입하여 이미 받은 행의 회수와 caller 소유권을 확인한다.
  표시 실패 후 옛 결과·요청 신원을 남기지 않는다.
- 20,000개 일치·20,000개 파일 그룹을 생성해 펼친 인덱스 40,000행을 검사한다. `Model.window`가
  viewport와 겹치는 행만 반환하며, 창 계산은 allocation을 하지 않는다. 모든 보관 allocation은 해제한다.
- 고정 머리·부분 행·좁은 폭·소수 배율·숨긴 필터·비활성 버튼·낡은 세대·중복 ID·부족한 frame/paint buffer를 검사한다.
  이 검사는 Chrome draw 명령과 tree 기하를 비교하며, 실제 Metal 픽셀이나 AppKit 입력을 증명하지 않는다.
- 문서 신원 확인·실패 시 무효화·자기 면 clip·조합 시작 차단·버튼 접근성 활성 판정을 각각 제거한
  대조군이 해당 실행 검사에서 실패했다. 원래 코드를 복원한 뒤 검사를 다시 실행한다.

## 재실행 명령

```sh
mise run test-editor-project-search-dock test-editor-project-search
mise exec -- zig build test-editor-project-search-dock test-editor-project-search -Doptimize=ReleaseFast
mise exec -- zig build test-editor-project-search-owner test-macos-project-search-adapter test-macos-project-search-worker test-macos-project-search-roots
mise run check
mise run macos-app-host-swift-check
```

모델과 컴포넌트 판정은 각각 기본 `maru`·Chrome 테스트에도 포함된다. 집중 실행 입구는 위 첫 명령이다.
성능 표본의 `testing` allocator는 누수 검사 비용을 포함한다. `smp` allocator는 앱 호스트와 같은 allocator를 사용하지만,
**이 역시 중립 모델 표본이지 앱 전체 RSS·main tick·첫 검색 결과·취소 지연 측정이 아니다.** 제품 byte 예산은 아직 정하지 않는다.

## 모델 실측 (2026-10-08)

ReleaseFast에서 앱 호스트와 같은 `smp_allocator`를 사용한 두 실행 표본이다.
20,000개 일치가 서로 다른 20,000개 파일 그룹에 속하는 합성 자료이며 미리보기는 `foo`다.

| 항목 | 관측값 |
|---|---|
| 모델 보관 allocation | 10,926,292 bytes (약 10.42MiB) |
| 행·그룹 추가 전체 | 4.86~5.32ms |
| 펼친 40,000행 인덱스 재구성 | 0.277~0.356ms |
| 모델 해제 | 0.476~0.644ms |
| viewport 창 계산 | allocation 0 |

이 값은 allocator 호출의 보관량이며 RSS가 아니다. allocator의 해제 후 page cache까지 OS에 반환한다는 뜻도 아니다.
긴 미리보기·경로·큰 열린 문서 사본이나 앱의 shape·paint·입력 비용을 포함하지 않으므로 제품 byte 예산으로 채택하지 않는다.
명령 출력의 `search-dock-model allocator=smp` 표본으로 다시 확인할 수 있다. 누수 검사용 `testing` allocator 표본은
스택·메타데이터 검사 비용을 포함하므로 앱 성능으로 읽지 않는다. 절대 시간에 의한 실패 gate는 추가하지 않았다.

## 아직 확인할 수 없는 제품 경계

앱의 도크 뷰·팔레트 명령·키/IME·worker batch 수신·실제 파일 이동이 미연결이므로 다음을 완료로 표시하지 않는다.

- 실제 우측/하단 도크, scrollbar·resize·포인터 누름/놓음 중 기하 변경, 접근성 입력 동작
- 물리 한국어 IME Enter·후보창 위치·포커스 이동, clipboard·선택 표시
- 열린 모델 revision·composition과 디스크 외부 변경을 확인한 클릭 이동
- 앱 전체 RSS·사본/결과/후보 byte 예산, 첫 결과·취소·main tick 지연
- 제품 Metal PNG 및 실제 화면 캡처

`begin`에 입력 transaction을 전달하고 worker 요청 전에 입력 소유자를 검증하는 배선,
완료 전에 남은 batch를 모두 소비하는 배선, 결과 소유권 이전·낡은 클릭 차단도 AppSession 연결 시 검증해야 한다.
기반 판정의 통과로 S1b/S2 전체 완료를 선언하지 않는다.
