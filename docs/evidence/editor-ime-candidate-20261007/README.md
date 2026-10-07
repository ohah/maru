# 실제 IME 후보창 전환·닫기 검증

수정 빌드로 후보창을 연 상태의 pane 닫기 5회와 A→B→A 전환 5회를 모두 통과했다. 전환은 재시작 후 공유 문서 복원까지 검사했다. 현재 결과는 `verification-current.json`과 `final-rounds.json`이 소유한다. PNG 및 전체 데스크톱 창 목록은 로컬에만 보관하고 저장소에 커밋하지 않는다.

macOS 한자 후보창은 `한`을 첫 후보 `韓`으로 바꾸는 콜백을 보낸다. 초기 드라이버의 한글 보존 기대값이 틀려 실패했으며, 관찰된 변환에 맞춰 기대값을 수정했다. 실제 입력 owner·문서 byte caret·저장 본문·후보창 소멸·독립 Vision OCR 검사를 모두 적용했다.

메타데이터 회귀 모음 5회와 실행 변이 6개 거부/동등 구현 2개 통과를 확인했다. 가짜 OCR 개수를 넣은 빈 PNG 5회는 독립 픽셀 검사에서 거부됐고, 독립 OCR을 제거한 컴파일 변이는 모두 잘못 통과했다. GUI 프로세스 소유권 8개 테스트는 정상·최적화 실행에서 통과했다.

`verification-pending.json` 및 `real-candidate-observations.json`은 수정 전 역사적 결과다. 수정 전 독립 관찰 통과와 전체 실행기 실패를 구분한다. 초기 SSH 직접 실행은 TCC 책임이 SSH wrapper에 귀속돼 거부됐고, 임시 GUI job의 LaunchServices 실행으로 해결했다. 실제 HOME 대조군이 남긴 workspace 변경은 직전 백업과 byte-identical하게 복구했으며, 이후 모든 실행은 격리 HOME을 사용했다.
