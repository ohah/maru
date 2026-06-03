# `tests/artifacts`

테스트 실패 시 생성되는 로컬 산출물을 담는 폴더다.

trace, snapshot, config, 로그 같은 실패 분석 자료가 들어갈 수 있다. 기본적으로 git에 커밋하지 않는다.

테스트는 가능한 경우 성공/실패와 무관하게 snapshot artifact를 남긴다. 실패했을 때만 출력되는 로그에 의존하면, UI/터미널 상태 버그를 비교하기 어렵기 때문이다.

현재 생성되는 예시는 다음과 같다.

```text
tests/artifacts/e2e/headless/*.screen.txt
tests/artifacts/e2e/headless/*.snapshot.txt
tests/artifacts/e2e/headless/*.stdout.txt
tests/artifacts/oracle/*/*.actual.txt
tests/artifacts/oracle/*/*.expected.txt
tests/artifacts/oracle/*/*.decoded.txt
tests/artifacts/oracle/*/*.snapshot.txt
```
