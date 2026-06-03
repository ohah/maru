# `tests/support`

테스트 공통 helper를 담는다.

현재는 snapshot artifact를 쓰는 helper가 있다. 테스트 파일이 직접 파일 시스템 세부 API를 반복해서 다루면 artifact 경로와 포맷이 흩어지기 때문에, 공통 helper를 통해 같은 방식으로 기록한다.

