# 코드 액션 결과의 위치 인코딩 소유

상태: 두 방향의 잘못된 본문 적용 재현·수정 및 최종 로컬 검사 통과. 원격 CI·머지는 별도로 확인한다.

바로 적용할 edit이 포함된 메뉴 항목의 위치는 그 결과를 낸 서버의 인코딩을 따른다.
같은 서버가 재시작해 다른 인코딩으로 협상해도 복사된 이전 edit의 위치를 다시 해석하지
않는다. lazy 항목의 resolve 응답은 그 응답을 실제로 낸 서버의 현재 인코딩을 사용한다.
기존 준비된 서버 조회·문서 버전·Save As·resolve 정책을 유지한다.

UTF-8/UTF-16 두 초기 서버에서 non-BMP 문자가 앞에 있는 편집을 메뉴로 게시한다.
fixture 소유 PID만 실제 종료하고, 같은/다른 인코딩의 새 PID가 ready된 뒤 이전 항목을
선택한다. 새 목록의 대기·positive/null/error 결과가 이전 항목의 인코딩을 바꾸는지도
대조한다. lazy resolve와 새로 게시한 메뉴는 현재 인코딩의 정상 대조다.

Owned 항목마다 결과 응답 시점 인코딩을 저장하고 ready edit만 그 값으로
적용한다. resolve 응답의 현재 인코딩은 유지한다. 내부 보유 결과 계약 변경에 맞춰 ABI와 C header·
고정 버전 경계·음성 변이 기준을 254→255로 동기화한다. 인코딩 변환 알고리즘이나 편집 정책은
새로 만들지 않는다.

서로 다른 조건 최소 20개, 정확한 본문·실제 파일·Undo와 정상 재적용을 확인한다.
집중 Debug/ReleaseFast, 메뉴 snapshot·origin·Save As·WorkspaceEdit·ABI·문서·전체 경계를
검증한다. 실제 프로세스/협상과 직접 응답 순서 제어를 구분하며 HID/픽셀 증거로 확대하지
않는다. 원시 자료는 저장소 밖 `~/Library/Caches/maru-verification/action-encoding-*`에 둔다.

## 발견과 수정

실제 PID 교체 뒤 UTF-8→UTF-16 협상에서 `a😀target; // CASTALL`의 target만 바꿀 edit이
`a😀taFIXED// CASTALL`로 적용됐다. UTF-16→UTF-8에서는 이모지 중간 바이트를 잘라
본문이 잘못된 UTF-8이 됐다. 원시 로그를 바이트로 보존하고 표시용 디코딩과 hex를 따로
기록했다. 같은 인코딩과 새 resolve 응답은 수정 전 정상 대조였으며, ready 두 검사는 실패했다.

onResponse가 Owned.encoding에 응답 인코딩을 값으로 저장하고 accept의 ready edit이
이를 사용하도록 고쳤다. 기존 현재 서버 준비/문서 조회와 lazy resolve의 현재 응답 인코딩은
유지했다. 새 목록의 대기·버려진 결과도 이전 항목의 인코딩을 바꾸지 않는다.

초기/재시작 인코딩 네 조합 × ready의 다섯 상태 20조건과 lazy resolve 네 조건이
Debug/ReleaseFast 모두 통과했다. 모든 조건에서 실제 새 PID와 협상 값, 정확한 본문·
적용/Undo·새 메뉴 재적용·실제 디스크 보존을 확인했다. 집중 gate는 행동 4개와 초기화
4개, 총 8개다. 메뉴 snapshot 6개·origin 10개·Save As 10개·WorkspaceEdit 21개도 두 모드에서
통과했다. 각 gate의 모듈 초기화를 고유 테스트 합계로 더하지 않는다.

Debug의 ABI 라이브러리·전체 경계·문서 링크/좌표와 Zig 포맷·diff가 통과했다. 그 뒤 별도로
실행한 macOS 앱 호스트 ABI 전체 계약 집계도 exit 0이다. 빌드가 정한 샤드·fresh 분리와
skip/filter를 유지하며 등록 수를 passed 합계로 더하지 않는다. 새 CAENC1~4와 버전 고정
검사도 집계에 포함됐다.

실제 ABI_contract_drift 기준을 격리 사본에서 255→254로 적용했다. 원본/정상 사본/변이/
복원 종료 코드는 0/0/1/0이고 실제 작업 소스 SHA는 같다. 이는 소스 경계 증거다.

원시 자료는 `action-encoding-before.log`·`action-encoding-before-evidence.json`,
`action-encoding-after.log`, `action-encoding-final-debug.log`·`action-encoding-final-releasefast.log`,
`action-encoding-abi-full.log`다. 조건별 PID·관측값과 최종 소스 SHA는
`action-encoding-final-cases.json`, ABI 음성 대조는 `action-encoding-abi-mutation.json`에 둔다.

## 후속 연결 소유 정책

[재시작 데이터 수명](lsp-code-action-restart-data.md)의 승인된 변경으로 옛 lazy 항목은
재시작 뒤 취소한다. CAENC3/4는 재시작 뒤 새로 요청한 lazy 목록과 새 resolve 응답의
현재 인코딩을 대조한다. ready의 원래 응답 인코딩 보존과 20조건은 유지한다. 위 최초
재현·검증 기록의 옛 lazy 항목 대조와 후속 정책의 전제를 구분한다.
