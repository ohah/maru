# 캐시 경로의 원격 커밋 검증

## 범위와 원인

상태: 로컬 구현·검증 완료. 실제 main `001033a79` 위에서 집중 5개와 전체 경계·문서/config 게이트가 통과했다. 다섯 명령 기록 손상과 여섯 배선 손상을 각각 거절했고 정상 대조군·원본 복원도 확인했다. PR CI·머지는 미완료다. 제품 정책은 변경하지 않는다.

`app_session/editor/mod.zig`의 `WT7c-1`은 실제 Git 저장소와 가짜 SSH transport를
통해 stage·원격 커밋의 stdin 전달을 검증한다. Zig의 임시 디렉터리는 현재 작업
디렉터리 아래에 생긴다. 기존의 `.cache` 부분 문자열 거절은 저장소 자체가 캐시
아래 있는 정상 명령도 거절했다. 같은 기존 바이너리의 일반 경로 → 캐시 경로 →
일반 경로 실행은 통과 → 실패 → 통과였다. SSH 환경 변수 제거로는 달라지지 않았다.

이 오류는 별도로 관측된 codesign 자식 종료 대기 CI 실패의 원인이 아니다.
그 타임아웃은 재현하지 못했으며, 대기 시간이나 제품 코드를 바꾸지 않는다.

## 판정과 실행

- 실제 `scm_dock_ops.testCommitMessagePath`가 반환하는 로컬 메시지 파일 경로만
  원격 명령에서 금지한다. 신뢰 관문·목적지·저장소 루트·선택한 stage 파일·
  `commit -F -`·실제 Git 메시지 검증은 유지한다.
- `test-editor-scm-cache-root`는 기존 편집기 판정자 모듈에서 `WT7c-1`을 고른다.
  별도 모듈 import만으로 제품 테스트가 포함됐다고 가정하지 않는다.
- 생성된 `.cache-scm-root`를 cwd로 사용하고 `MARU_TEST_SCM_CACHE_ROOT=1`을
  설정한다. 그 모드에서는 실제 canonical cwd에 `.cache`가 있는지 요구한다.
  일반 전체 시험은 해당 환경 변수를 설정하지 않는다.
- 선택한 실제 시험 하나와 기존 무명 import 판정자 네 개의 컴파일·macOS 통과
  수를 각각 5로 고정한다. 비 macOS에서는 실제 원격 시험이 기존대로 skip한다.
- macOS `test`와 `test-macos-app-host-abi`의 합류 실행은 전체 AppSession 샤드
  완료 뒤 같은 focused artifact를 별도 프로세스로 실행한다. 빠른 단독 명령에는
  전체 샤드를 붙이지 않는다. `test-macos-only`도 빠른 단독 실행을 포함한다.
  배선은 기존 샤드 boundary가 구조로 검증한다.

## 검증 명령과 한계

```sh
mise exec -- zig build test-editor-scm-cache-root -j2
mise exec -- zig build check-boundaries -j2
mise exec -- zig build check-doc-links check-doc-line-refs -j2
mise run check-config-docs
```

저장소 밖 private 사본 판정자는 실제 stage/commit 실행을 그대로 두고 읽은
SSH 명령 기록만 각각 손상시켜 목적지·루트·stage 파일·stdin 표시·실제 로컬
메시지 경로 유출을 독립적으로 거절하는지 검사한다. 정상 대조군과 시험 코드
복원·원본/계측 소스 및 바이너리 해시를 함께 보관한다. 이는 실제 SSH 서버·
GUI·OS 입력기 검증이 아니며, 관측하지 못한 CI 종료 타이밍의 원인을 증명하지 않는다.
