# `tests/artifacts`

테스트 실패 시 생성되는 로컬 산출물을 담는 폴더다.

trace, snapshot, config, 로그 같은 실패 분석 자료가 들어갈 수 있다. 기본적으로 git에 커밋하지 않는다.

테스트는 가능한 경우 성공/실패와 무관하게 snapshot artifact를 남긴다. 실패했을 때만 출력되는 로그에 의존하면, UI/터미널 상태 버그를 비교하기 어렵기 때문이다.

GitHub `CI` workflow는 `tests/artifacts/**`를 업로드한다. 그래서 로컬에서만 보는 파일이 아니라, PR 실패 시 GitHub Actions 화면에서도 같은 screen/snapshot/summary를 내려받아 확인할 수 있다.

GitHub `Performance` workflow는 `tests/artifacts/perf/**`를 별도 artifact로 업로드한다. 성능 숫자는 runner 상태에 영향을 받으므로 PR 필수 게이트가 아니라 장기 추적용으로 사용한다.

현재 생성되는 예시는 다음과 같다.

```text
tests/artifacts/e2e/headless/*.screen.txt
tests/artifacts/e2e/headless/*.snapshot.txt
tests/artifacts/e2e/headless/*.stdout.txt
tests/artifacts/oracle/*/*.actual.txt
tests/artifacts/oracle/*/*.expected.txt
tests/artifacts/oracle/*/input.decoded.txt
tests/artifacts/oracle/*/*.snapshot.txt
tests/artifacts/stress/*/*.screen.txt
tests/artifacts/stress/*/*.snapshot.txt
tests/artifacts/stress/*/*.summary.txt
tests/artifacts/perf/*.txt
```
