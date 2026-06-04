# Snapshot Versioning

이 문서는 snapshot schema version을 언제 유지하고 언제 올릴지 정한다.

## 한 줄 정의

Snapshot version은 제품 버전이 아니라 **테스트와 디버깅 데이터 계약 버전**이다.

현재 schema는 `maru.snapshot.v1`이다.

## 왜 필요한가

터미널 snapshot은 단순 문자열이 아니다. 다음 상태가 함께 들어간다.

- 화면 크기
- cursor 위치와 표시 여부
- dirty region
- cell text
- style
- future mode
- future scrollback
- future alternate screen

이 구조의 의미가 바뀌면, 오래된 artifact나 fixture를 어떻게 읽어야 하는지 알 수 없게 된다. 그래서 version을 둔다.

## 버전을 올리는 경우

다음은 `maru.snapshot.v2`처럼 version을 올린다.

- 기존 필드의 의미가 바뀐다.
- cell 표현 방식이 바뀐다. 예: `text` 하나에서 `codepoint + width + continuation`으로 바뀐다.
- cursor, style, alternate screen, scrollback을 reader가 다르게 해석해야 한다.
- replay나 inspector가 기존 v1 reader로는 안전하게 읽을 수 없다.
- 같은 terminal state가 기존 규칙과 다른 snapshot 의미를 갖게 된다.

## 버전을 유지할 수 있는 경우

다음은 version을 유지할 수 있다.

- 사람이 읽기 위한 non-semantic debug line을 추가한다.
- 기존 reader가 무시할 수 있는 optional metadata를 추가한다.
- artifact 파일명이나 저장 위치만 바뀐다.
- 단순히 expected output fixture가 바뀐다.
- 버그 수정으로 실제 화면 결과가 바뀌었지만 snapshot schema 의미는 그대로다.

주의: version을 유지하려면 old consumer가 깨지지 않는다는 근거가 있어야 한다. 근거가 애매하면 version을 올리는 쪽이 안전하다.

## v1 reader 규칙

초기 v1 reader는 보수적으로 동작한다.

- 첫 줄 전체가 bare 토큰 `maru.snapshot.v1`인지 확인한다. `schema=` 같은 접두어 없이 첫 줄이 곧 schema 토큰이다(현재 코드가 내보내는 형식).
- 알 수 없는 semantic section을 만나면 실패한다.
- `debug.` prefix를 가진 non-semantic line은 무시할 수 있다.

이 규칙의 의도는 조용히 잘못 해석하는 것을 막는 것이다.

## PR 규칙

snapshot 출력이 바뀌는 PR은 PR 설명에 다음을 적는다.

```text
snapshot schema version:
  유지 / v2로 증가

이유:
  schema 의미 변경인지, 단순 expected output 변경인지

consumer 영향:
  replay, inspector, golden, artifact reader가 영향을 받는지
```

## 초기 테스트

- snapshot text 첫 줄에 schema가 있다.
- v1 reader가 v1 snapshot을 읽는다.
- v1 reader가 모르는 semantic section을 만나면 실패한다.
- debug-only line 추가는 version bump 없이 허용된다.
