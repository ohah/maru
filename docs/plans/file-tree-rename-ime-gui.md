# 파일 탐색기 이름 변경의 실제 IME 검증

상태: 선택 유실 수정·실제 GUI 5개 장면·순수 회귀와 독립 디스크/identity 검사 완료. CI는 PR에서 확인한다.

## 범위와 기존 증거

workspace 이름 변경(#4583), named Save As(#4630), 이름 없는 문서 첫 저장(#4632)은 완료됐다.
같은 `rename_input`을 쓰지만 탐색기는 기존 파일 identity·행 선택·비동기 rename backend를 소비한다.
이번에는 **열지 않은 로컬 일반 파일** 하나의 실제 한글·한자 파일명 변경과 취소·대상 충돌·쓰기 권한
실패를 검증한다. 열려 있는 문서의 path remap·디렉터리/원격/심링크 rename은 기존 계약과 별도 증거다.
충돌은 기존 정책대로 거절하며 덮어쓰기 UX나 경로·보안 정책을 바꾸지 않는다.

## 계약과 실행

private fixture는 사유 project와 원본 `base`, 무관한 dirty 문서를 준비하고 materialized tree row를
선택해 제품 `startFileTreeEdit(.rename)`으로 이름 입력을 연다. 실제 OS 두벌식으로 `base한`, 한자
후보로 `base韓`을 만든다. 후보 취소/선택 Enter 뒤에도 원본 경로·내용·identity를 유지하고 mutation은
대기하지 않아야 한다. 별도 Enter에서만 backend rename을 시작한다. Escape는 파일을 바꾸지 않는다.

성공은 실제 원본 경로 부재, 새 경로의 원본 bytes·동일 device/inode, 새 tree 선택과 pending 정산으로
판정한다. 충돌 시 기존 목적지 sentinel과 원본 모두 보존하며, 사유 폴더 쓰기 권한 실패도 원본을 보존한다.
모든 경우 무관한 dirty 문서·본문·surface와 입력 소스 복원을 확인한다. 사용자 파일/설정/권한은 바꾸지 않는다.

첫 저장 하네스의 source-copy·guarded HID·native 창 capture를 재사용하고 private observer와 단계
마무리만 파일 rename용으로 교체한다. 이미지·원시 자료는 저장소 밖에 보존하며 PNG는 PR 본문에만
업로드한다. 합성 손상·판정 제거 사본은 실제 GUI 횟수로 세지 않으며 20개 이상 서로 다른 공격 조건과
정상 대조군을 포함한다. 픽셀은 창 연결·해시와 직접 확인을 사용하며 후보 OCR·VoiceOver를 주장하지 않는다.

## 실제로 발견한 선택 유실과 수정 계약

수정 전 실제 한자 rename은 디스크에서 성공했지만 선택이 부모 root로 이동했다. private 계측은
`TREE_RESULT admitted=1 current=1`에서 새 이름을 선택한 뒤, `expanded=true loading=true`인 부모와
이전 이름 행만 있는 목록에서 선택 generation이 2→3으로 바뀌며 root로 떨어지는 순서를 확인했다.
이는 후보 Enter 조기 실행이 아니라 완료 뒤 비동기 목록 재투영의 결함이다.

`Selection.setIdentity`의 기존 약속(새 행 도착 전 신원 예약)을 지키도록 순수
`src/session/file_tree_navigation.zig`의 reconcile 판정을 수정한다. exact identity가 없고 fallback의
가장 깊은 조상이 expanded·loading이면 결과를 아직 결정하지 않고 선택 신원/generation을 유지한다.
목록이 완료돼도 없는 파일, 접힌 조상, 다른 경로, 같은 경로의 종류 변경은 기존 fallback을 유지한다.
exact 행과 명시적 사용자 선택은 항상 우선한다. OS나 host에 같은 정책을 복제하지 않는다.

새 순수 회귀는 수정 전 행동 실패를 먼저 확인하며, 로딩→exact 도착·완료 후 부재·접힘·중첩 부모·
사용자 선택·경로 prefix/종류 변경을 함께 검증한다. 기존 전용 `test-file-tree-model`의 낡은 compiled
개수 계약도 실제 그래프에 맞춘다. 개수 불일치 실패를 제품 결함 주입의 성공으로 세지 않는다.

## 결과와 증거 보존

수정 전 GUI 세 실행은 모두 파일 rename 뒤 선택이 root로 바뀌어 실패했다. 계측 대조군은 부모가
loading인 이전 `base` 행 목록에서 새 `base韓` 예약을 조상으로 덮는 것을 확인했다. 순수 회귀도
기존 코드에서 `expected null, found 0`으로 실패했고 수정 뒤 전체 모델 게이트 34개가 통과했다.

수정 앱의 한자·한글 rename, 입력 취소, 기존 이름 충돌, 사유 폴더 권한 오류 5개가 모두 통과했다.
후보 Return 뒤 원본 경로·inode·bytes 보존, 별도 Enter 뒤 성공한 rename의 동일 device/inode와
새 트리 선택, 실패/취소 시 원본과 기존 목적지 보존을 확인했다. 무관한 dirty 문서도 보존됐다.

증거 복사본은 inode가 새로 생기므로 원본 stat와 같은 값으로 비교하지 않는다. 실제 실행 root에서
부모 runner가 종료 후 identity/bytes를 `after-identity.json`에 기록하고 live 검사기는 실제 stat를
대조한다. 복사본의 독립 검증은 그 원본 identity 기록·PID/root 연결·복사된 bytes/hash를 대조한다.
복사본 inode 자체를 원본의 inode라고 주장하지 않는다. 이 차이를 놓친 최초 수정 앱의 보고 실패도
제품 rename 실패로 계산하지 않고 따로 보존했다.

`~/Library/Caches/maru-verification/file-tree-rename-ime-20261028-control{,-v2,-v3}`는 수정 전 실패,
`...-fixed-hanja`는 복사본 inode 판정 실패, `...-fixed-v2-*`는 최종 실제 5개 장면이다.
`...-independent-final.json`은 최종 검사기로 다시 대조한 결과와 검사기 해시를 보존한다.
`...-product-mutations-v2`의 로딩 유지 제거·loading 무시·접힘 무시·경로 경계 무시·종류 변경 유지
사본 5개는 모두 컴파일 후 행동 단언에서 실패했고 원본 전후 대조군은 통과했다. 초기 `...-product-mutations`
실험의 unused local 컴파일 오류는 결함 검출로 세지 않는다. 합성 기록 손상 대조군은 실제 GUI와 별개다.

후보·이름 입력·최종 선택 이미지는 저장소 밖에 보존하며 PR 본문에만 업로드한다. 원격·디렉터리·
열린 문서 remap·VoiceOver·후보 OCR·다른 OS의 실제 GUI로 결과를 확대하지 않는다.
