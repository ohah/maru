# 개발 명령

Maru 작업에서 사용하는 기본 명령이다.

## 도구

- 도구 설치/선택: `mise install`
- Zig 버전 확인: `zig version`
- mise가 선택한 Zig 확인: `mise current zig`

## 빌드와 테스트

- 빌드: `mise run build`
- 테스트: `mise run test`
- E2E 테스트: `mise run e2e`
- 오라클 비교 테스트: `mise run oracle`
- 빠른 스트레스 테스트: `mise run stress`
- 긴 opt-in 스트레스 테스트: `mise run stress-soak`
- 성능 예산 측정: `mise run perf`
- 포맷: `mise run fmt`
- 전체 확인: `mise run check`
- Zig 테스트 직접 실행: `zig build test`

## 완료 전 확인

코드나 빌드 설정을 바꾼 PR은 기본적으로 다음을 통과해야 한다.

```sh
mise run check
git diff --check
```

문서만 바꾼 PR은 `git diff --check`를 최소 검증으로 사용한다. 다만 문서가 명령, 구조, 테스트 경로를 바꾸면 관련 명령도 함께 실행한다.
