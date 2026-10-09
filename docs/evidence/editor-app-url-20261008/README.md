# 에디터 앱 URL 구현 검증

파일 열기에서 FIFO가 앱을 멈출 가능성을 발견했다. nonblocking으로 열고 같은 descriptor가
정규 파일인지 확인하도록 수정했다. URL 처리의 IME 확정도 선택한 창의 `withSurface`
경계에서 수행하도록 보완했다.

변이 검증 도구가 이전 정상 빌드의 캐시를 재사용해 잘못 통과하는 문제는 절대 소스 경로와
사례별 캐시로 수정했다. 이후 추가 검증에서는 새로운 결함을 발견하지 못했다.

파서·큐·네이티브 이동의 Debug/ReleaseFast 검사, Swift 처리 검사, 공유 pane 회귀,
앱 번들 빌드와 전체 경계 검사는 통과했다.

실제 OS URL 전달은 사용자 macOS GUI 터미널 실행에서 통과했다. 같은 빌드로 콜드 실행의
파일·위치 열기, 웜 실행의 위치 이동, 파일 재사용과 커서 유지, 잘못된 줄 번호 거부를
확인했다. 실행 파일 SHA, 생성 파일 bytes와 경로 hash, receipt 순서·surface·byte caret도
산출물에서 독립 대조했다. [결과](os-terminal-result.json)와 [수신 로그](os-terminal-receipts.log)를 참조한다.

이전 도구 실행에서는 LaunchServices `-10827` 및 직접 실행 `-6`이 발생했다. 직접 실행의
abort는 URL 처리 전 AppKit 앱 등록 단계였다. 같은 빌드가 GUI 터미널에서 통과했으므로
도구 실행 환경의 차이로 좁혀졌다. Background 세션과 샌드박스의 개별 영향은 분리하지 않았다.
기본 handler 선택, 화면·접힘 확인과 PR/CI는 아직 미완료다.

상세 결과는 [검증 상태](verification.json), [파서·큐 변이](adversarial.json),
[Swift 처리 변이](host-mutations.json), [추가 검증](additional-three.json)에 보관한다.
재실행은 `python3 docs/evidence/editor-app-url-20261008/repeat-three.py --output <아직 없는 출력 경로>`.
전체 실패 로그와 생성 산출물은 로컬에 보관하며 PNG는 저장소에 커밋하지 않는다.
