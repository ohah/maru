# 에디터 Surface 전략 (코드 에디터·git diff·저장·도구·LSP)

이 문서는 Maru에 코드 에디터 surface를 추가하는 계획의 단일 출처다. 첫 제품 가치는 에이전트가 만든 변경을 사용자가 Maru 안에서 검토하는 것이고, 이후 같은 문서 모델 위에 편집·저장·포맷/린트·LSP를 얹는다.

경계:

- WKWebView 합성·입력·`maru-app://`·CSP는 [web-panel.md](web-panel.md)가 소유한다.
- 외부 프로세스의 Unix socket 인증과 capability 발급은 [control-plane.md](control-plane.md)가 소유한다.
- 레이어 경계는 [layering-and-portability.md](layering-and-portability.md), surface 생애주기는 [surface-runtime-api.md](surface-runtime-api.md)를 따른다.
- **전역 도크 레이아웃·`.md`/`.html` 뷰어·CM6 편집기·파일 read/write 채널·vanilla 웹 스택은 [file-panel.md](file-panel.md)가 소유한다.** git diff·editor는 그 위 확장으로 정합한다(§3.1·§10.0). 여기서 재서술하지 않는다.
- 이 문서는 editor 전용 bridge/grant, 문서 revision, safe-save CAS, 외부 변경 감시, diff/도구/LSP API와 단계 gate를 소유한다.

## 1. 2026-07-16 적대적 PoC 결론

이번 PoC는 임시 로컬 하니스로 수행했다. 결과 자체는 설계 근거지만 아직 저장소의 반복 가능한 자동 테스트가 아니다. Phase 0.5의 첫 PR은 같은 검증을 제품 하니스로 커밋해야 한다.

| 가정 | 결과 | 설계 반영 |
| --- | --- | --- |
| zntc가 Monaco를 번들할 수 있다 | **부분 통과.** zntc `16f1fda0055f844b77520cbdc4dc329cb294fef4`에서 NAPI/core/web 빌드와 Monaco semantic parity 테스트 통과. npm 최신 `0.1.3`에는 해당 수정이 모두 릴리스되지 않았다. | 아직 최소 릴리스 버전을 확정하지 않는다. 수정 포함 릴리스를 기다리거나 commit pin을 별도 승인한다. |
| Chrome에서 Vite와 픽셀이 같으면 제품에서도 된다 | **기각.** zntc 자체도 CI pixel flake 때문에 Monaco 필수 oracle을 semantic comparison으로 바꿨다. Chrome 결과는 WebKit 증거가 아니다. | 일반 CI는 semantic oracle, pixel은 선택 artifact/툴체인 qualification. 제품 gate는 별도 WKWebView E2E다. |
| 현행 엄격 CSP에서 Monaco가 동작한다 | **실패.** `style-src 'self'`에서 Monaco가 삽입한 inline `<style>`과 style attribute가 차단됐다. `unsafe-inline`을 열면 CSP 위반은 사라지고 worker/diff 계산은 동작했다. | editor 전용 CSP 결정이 필요하다. markdown CSP를 전역으로 약화하지 않는다. |
| custom scheme + module worker가 WebKit에서 된다 | **부분 통과.** `maru-poc://`에서 module 평가, worker, diff decoration 계산은 성공했다. | worker/asset 배선은 가능성이 높지만 편집기 전체 통과로 간주하지 않는다. |
| Monaco가 WKWebView에서 정상 표시·입력된다 | **실패/미해결.** window에 붙인 하니스에서도 view-line layout/text가 정상 렌더되지 않았다. Vite와 zntc 산출물이 같은 증상을 보여 zntc 고유 문제로 좁혀지지 않았다. caret·편집·한글 IME도 미검증이다. | **Phase 0.5A RED blocker.** 텍스트·caret·ASCII 편집·한글 조합/NFD·backspace가 제품 WKWebView에서 통과하기 전 Monaco 채택과 Phase 1을 확정하지 않는다. |
| isolated content world의 bridge를 page가 호출할 수 있다 | **부분 통과.** `CustomEvent`는 world를 넘지 않았지만 DOM attribute mailbox+`MutationObserver` 왕복은 성공했고 page의 `window.maru`는 계속 `undefined`였다. | 기술적으로 가능하지만 DOM은 보안 경계가 아니다. native allowlist/grant가 필수다. editor에는 더 단순한 전용 page-world shim을 권장한다. |
| 기존 atomic helper를 저장에 재사용하면 안전하다 | **기각.** `createFileAtomic(.replace=true,.make_path=true)` PoC에서 기존 mode `0640`이 `0644`로 바뀌었고 symlink 자체를 regular file로 교체했다. | editor 전용 safe-save를 구현한다. mode/symlink/xattr/ACL/fsync 정책과 CAS가 선행돼야 한다. |
| 열린 파일 FD를 감시하면 atomic replace도 계속 잡힌다 | **기각.** file-FD `DispatchSource`는 replace 때 delete만 받고 새 inode의 후속 write를 놓쳤다. directory-FD는 replace와 후속 write를 모두 신호했다. | 디렉터리 단위 감시 후 열린 문서를 재-stat/hash한다. watcher 이벤트는 힌트이고 hash가 권위다. |
| 포맷/린트는 가벼운 비신뢰 실행이다 | **기각.** Prettier config import가 임의 JS를 실행함을 실측했다. | LSP와 동일한 workspace tool-execution 신뢰 경계를 적용한다. |
| 저장 ack 하나로 dirty를 지울 수 있다 | **기각.** save 중 추가 편집이 있으면 이전 revision ack가 최신 dirty를 지우면 안 된다. 외부 disk hash 변경도 별도 충돌이다. | `editor_revision`, `persisted_editor_revision`, `disk_fingerprint` 3축 CAS를 사용한다. |
| diff before/after 전체 blob을 JSON-RPC로 보낼 수 있다 | **기각.** socket frame 상한은 1 MiB이고 현재 bridge 결과 버퍼는 8 KiB다. `app_session.zig` 한 파일만 약 2.78 MiB다. | metadata 목록과 파일별 bounded open으로 분리한다. UI는 socket을 우회해 공통 L2 dispatcher를 직접 호출한다. |

## 2. 현재 코드에서 확인한 경계

- `PanelKind`는 단순 trust bit가 아니다. label·DTO·layout·host config·복원 모델에 관여하는 의미 있는 종류다. 현재 `{ markdown, browser }`뿐이므로 editor를 markdown 라우트로 위장하면 권한과 lifecycle이 결합된다.
- 현행 trusted markdown bridge는 named `WKContentWorld`에만 존재하고 page world의 `window.maru`는 의도적으로 없다. 제품 smoke에서도 isolated probe=`object`, page-world probe=`undefined`, bridge hello=`0.1.0`을 확인했다.
- control dispatcher에는 metadata뿐 아니라 browser 전용 authenticated/deferred 경로가 이미 있다. 그러나 editor/file용 generic dispatcher와 제품 capability fd 발급 경로는 없다.
- 현행 CSP는 `default-src 'none'; script-src 'self'; img-src 'self' data:; style-src 'self'; connect-src 'none'`다.
- control socket 최대 frame은 1 MiB다. 브리지 응답도 현재 fixed 8 KiB라 큰 문서 전송 경로로 사용할 수 없다.

## 3. 권장 구조

```text
editor WKWebView (Monaco, current text/undo/cursor)
  -> editor-only page shim (bounded request/event DTO)
  -> native editor bridge (method allowlist + EditorGrant)
  -> L2 EditorDispatcher / EditorCore
       |- DocumentRegistry (identity/revision/disk fingerprint/conflict)
       |- path/grant/CAS/diff DTO policy
       `- injected adapter interfaces
            |- L4 FileAdapter (descriptor-safe read/save/stat/hash)
            |- L4 WatchAdapter (DispatchSource/FSEvents)
            |- L4 GitAdapter (bounded read-only git invocation)
            `- L4 ToolAdapter (formatter/linter/LSP process)

external CLI/agent
  -> Unix socket + capability nonce
  -> same L2 policy/services
```

제품 UI 요청을 자기 Unix socket으로 되돌려 보내지 않는다. socket 인증은 외부 프로세스 경계용이고, in-process bridge는 host가 surface에 결합한 grant를 검증한 뒤 같은 L2 dispatcher를 직접 호출한다. 이 구분으로 payload 복사·deadlock·자기 인증 우회를 피한다.

L2는 file descriptor, DispatchSource, FSEvents, child process, AppKit/WebKit 타입을 몰라야 한다. grant 판정·문서 상태·CAS 전이·DTO/error mapping은 `src/session/`의 순수 코어가 소유하고, 실제 파일·git·watch·process I/O는 `src/app` 공통 runtime 또는 `src/platform/macos` adapter가 주입한다. `check-boundaries`에 editor 코어의 platform import 금지를 추가한다.

### 3.1 kind와 trust 경계 (도크 정합 종속)

**먼저 §10.0을 정한다.** git diff·editor를 (a) 파일 패널 도크의 새 콘텐츠 kind로 넣을지, (b) 별도 `.editor` surface로 둘지가 이 절의 형태를 정한다. 사용자 방향("마크다운 뷰어와 동일 레이아웃")은 (a)로 기운다.

- **(a) 도크 확장이면**: 파일 패널의 kind 분기([file-panel.md](file-panel.md) §2)에 diff/code 콘텐츠 kind를 additive로 더한다. 새 top-level `PanelKind`가 아니라 도크 내부 kind이며, origin/CSP/grant만 아래 trust 계단대로 분리한다.
- **(b) 별도 surface면**: `.editor`를 닫힌 enum에 추가한다(구현 전 사용자 승인 필요). 그 경우 한 PR에서: L2 `PanelKind`·wire·session model label/detail·layout/restore, macOS ABI `panel_kind` 상수·layout 계약·Swift 분기, editor 전용 exact origin(`maru-app://editor`)·asset root·CSP·data-store, lifecycle/close/crash/reload와 surface별 `EditorGrant` 회수.

어느 쪽이든 아래 trust 경계는 동일하게 적용한다.

**정정: 마크다운 뷰어도 파일시스템을 만진다.** [file-panel.md](file-panel.md)의 파일 패널은 `.md`/`.html`을 `loadFileURL(allowingReadAccessTo:)`로 **읽고**(디렉터리 스코프), 열린 핀 경로 하나에만 `maru.file.write`로 **쓴다**(§3, write 스코프=열린 파일만). 즉 markdown은 "표시 전용/파일시스템 0"이 아니라 **경로가 고정된 읽기 + 좁은 쓰기**다. 여기서 진짜 신뢰 경계는 read/write 유무가 아니라 **범위**다.

신뢰 등급(범위 기준):

- **마크다운 뷰어(file-panel)**: 핀 파일 read(+ 좁은 write). 파일별로 열 때 확정, JS가 확대 불가.
- **read-only git diff**: 파일 write 없음. worktree/HEAD blob **read** + bounded `git_read`. → 신뢰 수준이 full editor보다 마크다운 뷰어에 가깝다.
- **editor(편집)**: 여기서 `file_write`가 붙는다. 이게 계단의 실제 단차다.

그러므로 **editor 파일 write op를 markdown/뷰어 route에 얹지 않는다**(범위 확대 금지). `browser`는 계속 untrusted이며 editor bridge와 `maru-app://` asset에 접근하지 못한다.

**레이아웃은 공유, trust는 분리(사용자 방향).** git diff·editor는 [file-panel.md](file-panel.md)의 전역 도크와 **동일한 시각 shell**(탭 스트립·헤더 밴드·파일 트리 = GPU chrome, 콘텐츠 rect = WKWebView)을 공유해 UX 일관성과 코드 재사용을 얻는다. 실제로 git diff는 도크의 **또 다른 콘텐츠 kind**(현행 `.md`/`.html` 옆)로 보는 게 자연스럽다. **다만 레이아웃 재사용이 trust 재사용을 뜻하지 않는다** — 같은 도크 안에서도 kind별 origin/CSP/grant는 위 계단대로 분리한다. 이 도크 정합·엔진(CM6/Monaco) 정합은 §10 결정 항목이다.

editor가 markdown과 같은 `maru-app://app` origin을 공유하면 origin pin만으로 두 콘텐츠의 권한을 구분할 수 없다. editor bridge는 main frame + editor exact origin + 해당 `surface_id`의 `.editor` kind를 모두 확인하고, remote/top-level navigation을 거부한다. editor page에서 markdown asset route로 이동해도 grant가 유지되는 구조는 허용하지 않는다.

### 3.2 editor bridge와 grant

Monaco page가 네이티브 API를 호출해야 하므로 editor에는 좁은 page-world shim을 둔다. isolated-world DOM mailbox도 가능하나 page가 mailbox를 쓸 수 있어 보안상 더 강하지 않고 구현 복잡도만 늘어난다.

`EditorGrant`는 JS가 고르는 bearer nonce가 아니라 native host가 editor surface 생성 시 결합하는 리소스 권한이다.

```text
EditorGrant {
  surface_id,
  root_id,
  file_read,
  file_write,
  git_read,
  tool_execute,
}
```

규칙:

- 모든 요청은 bridge가 가진 `surface_id`와 native grant를 사용한다. JS가 root나 scope를 확대할 수 없다.
- `root_id`는 native가 열린 canonical root descriptor와 매핑하는 opaque id다. page에는 root 절대 경로나 descriptor를 권한 토큰처럼 주지 않는다.
- 경로는 root 기준 상대 경로만 받고 NUL, absolute path, `..`, symlink escape를 거부한다.
- `file_write`, `git_read`, `tool_execute`는 각각 분리한다. repo를 읽을 수 있다고 명령 실행까지 허용하지 않는다.
- request/result의 byte·item·time 상한, cancellation, surface close/revoke 시 terminal completion을 정의한다.
- push는 bounded editor event channel로만 전달한다. unbounded `evaluateJavaScript` 문자열 조립을 프로토콜로 삼지 않는다.

외부 CLI/agent가 같은 op를 쓸 때만 control-plane capability nonce를 사용한다. 제품 capability fd 실발급이 붙기 전에는 외부 file/tool op를 열지 않는다.

### 3.3 bridge 프로토콜과 생애주기

bridge는 임의 JS 객체 호출 모음이 아니라 버전 있는 protocol로 고정한다.

```text
EditorRequest {
  protocol_version,
  request_id,
  surface_id,
  method,
  params,
}

EditorResult = success | typed_error
```

- `surface_id`는 page 입력을 신뢰하지 않고 handler가 자신에게 결합된 값을 덮어쓴다.
- `request_id`는 surface 안에서 단조 증가하며 중복·이미 완료·취소 후 완료를 거부한다.
- method별 request/result byte, item, page, timeout 상한을 스키마와 테스트에 함께 둔다. E1 착수 전 실제 숫자를 확정한다.
- error는 최소 `invalid_request`, `unauthorized`, `outside_root`, `not_found`, `unsupported_encoding`, `too_large`, `binary`, `conflict`, `cancelled`, `tool_failed`, `internal_error`로 구분한다. 내부 경로·errno·프로세스 환경은 page에 그대로 노출하지 않는다.
- surface close, navigation, web-content process crash, workspace revoke 때 모든 pending request를 정확히 한 번 `cancelled`로 끝내고 adapter 작업도 취소한다. 늦은 callback은 새 surface/grant에 적용하지 않는다.
- page reload마다 bridge epoch를 새로 발급한다. 이전 epoch의 response/event는 버린다.
- push queue는 bounded이며 coalesce 가능한 diagnostic/watch 상태와 유실 불가 save completion을 구분한다. overflow를 조용히 drop하지 않는다.
- bridge DTO는 UTF-8 JSON을 쓰되 문서 bytes를 JSON string에 무제한 인라인하지 않는다. 상한 이하 UTF-8 text만 인라인하고, 이후 큰 payload transport는 별도 설계 전까지 거부한다.

### 3.4 예상 코드 배치

구현이 다시 `app_session.zig`와 `MaruAppHost.swift` 한 파일에 누적되지 않도록 첫 slice부터 책임별 파일로 나눈다.

```text
src/session/editor/
  protocol.zig           version/error/DTO/limit
  grant.zig              EditorGrant/path scope policy
  document_registry.zig  revision/owner/conflict/recovery state
  diff_model.zig         stable snapshot/status DTO

src/app/
  editor_runtime.zig     adapter orchestration/cancel/queue

src/platform/macos/
  editor_file.zig        descriptor-relative file adapter
  editor_watch.zig       DispatchSource/FSEvents adapter
  editor_tool.zig        git/tool/LSP process adapter
  MaruEditorBridge.swift WKWebView bridge/epoch/main-frame/origin adapter

web/editor/
  entry/assets/tests     editor app와 semantic oracle
```

`src/session.zig`는 editor L2 facade만 export하고 Swift 새 파일은 `build.zig`의 `swiftc` 입력과 swift-check에 함께 연결한다. 실제 디렉터리를 추가하는 PR은 [project-structure.md](project-structure.md)도 같은 PR에서 갱신한다. app-global `DocumentRegistry`의 runtime owner는 per-window `AppSession`이 아니라 전 창이 공유하는 `AppRuntime` 계층에 둔다.

## 4. 문서 권위와 저장 CAS

Monaco가 열린 문서의 현재 text, undo stack, selection/cursor를 소유한다. `DocumentRegistry`는 앱 전역으로 하나를 두어 window/surface가 달라도 같은 파일 identity를 공유한다. 같은 파일을 독립 model 두 개로 열어 각자 저장하게 두는 구조는 CAS 충돌을 정상 UX로 가장하므로 허용하지 않는다.

native가 전체 text 정본을 보유하지 않는 v1에서는 한 document에 **writable Monaco owner surface 하나**만 둔다. 두 번째 open은 기존 owner를 focus하거나 명시적 read-only snapshot을 연다. owner close/move/crash 때 dirty 여부를 확인한 뒤 owner를 transfer/recover하며, 두 page의 editable model을 실시간 동기화하는 것은 native canonical text 또는 CRDT/OT가 필요하므로 v1 범위 밖이다.

L2 `DocumentRegistry`는 동일 text의 두 번째 정본을 상시 유지하지 않고 다음 상태를 소유한다.

```text
DocumentState {
  document_id,
  document_key,
  editor_revision,
  persisted_editor_revision,
  disk_fingerprint,
  conflict,
  subscribers,
  recovery_state,
}
```

- `document_key`는 단순 path 문자열이 아니라 grant `root_id` + 상대 경로 + 열린 시점 file identity를 포함한다. rename/replace 뒤에는 정책에 따라 같은 문서 identity를 유지하거나 명시적으로 새 문서로 전환한다.
- page는 `document_id`와 path의 대응을 선택할 수 없다. native가 `file.open`에서 결합하고 이후 save/change 요청은 그 결합을 사용한다.
- page의 content change마다 `editor_revision`이 단조 증가한다.
- save 요청은 `{document_id, editor_revision, expected_disk_fingerprint, bytes}`를 보낸다. 초기 버전은 bounded full text를 허용하되 큰 파일 상한을 둔다. 증분 edit 프로토콜은 필요가 측정될 때 추가한다.
- native는 write 직전에 disk fingerprint를 다시 비교한다. 다르면 쓰지 않고 conflict를 반환한다.
- save ack는 저장된 revision과 새 disk fingerprint를 돌려준다. ack 뒤 현재 editor revision이 더 크면 dirty는 유지한다.
- 외부 변경을 받아들일 때 통짜 model 교체로 undo/cursor를 깨지 않는다. clean 문서는 최소 edit로 갱신하고, dirty 문서는 reload/keep/compare를 사용자에게 선택하게 한다.
- fingerprint는 적어도 file identity, size, mtime, content hash를 포함하되 최종 authority는 content hash다.
- watcher가 자기 save를 다시 외부 변경으로 보고하지 않도록 save operation id와 결과 fingerprint를 기록한다. 단 operation id만으로 무시하지 않고 실제 hash가 예상값과 같을 때만 self-write로 접는다.
- dirty owner surface를 닫거나 workspace/window를 종료할 때 save/discard/cancel을 묻는다. discard는 메모리 buffer 폐기이지 `git discard`가 아니다. app 종료 중 여러 dirty document의 순서·일괄 취소·save 실패 후 종료 중단을 상태머신 테스트로 고정한다.

### 4.1 텍스트 포맷 계약

Monaco 문자열과 디스크 bytes 사이 변환을 암묵적으로 UTF-8이라고 가정하지 않는다.

- v1 지원 범위는 UTF-8(선택적 BOM) 텍스트로 제한하는 것을 권장한다. invalid UTF-8, UTF-16/32, binary는 읽기 전용 hex/external-open 또는 typed `unsupported_encoding`으로 거부한다.
- open 결과는 `encoding`, `bom`, `line_ending`(`lf|crlf|mixed`), `has_final_newline`을 함께 반환한다.
- save 기본은 원본 BOM·우세 개행·마지막 newline 상태 보존이다. 사용자가 명시적으로 바꾸지 않은 포맷을 formatter 결과 때문에 조용히 바꾸지 않는다.
- mixed line ending을 정규화할지 보존할지는 최초 저장 UX 전에 결정한다.
- Monaco UTF-16 offset과 LSP UTF-16 position, 디스크 UTF-8 byte offset을 별도 타입으로 다룬다. byte offset을 editor/LSP position으로 재사용하지 않는다.
- NUL 포함 파일, 매우 긴 한 줄, combining/NFD, lone CR, final newline 없음 fixture를 둔다.

### 4.2 unsaved recovery와 restore

“crash recovery green”만으로는 완료 조건이 아니다. 복구 데이터의 수명과 민감정보 정책을 먼저 정한다.

- 기본 workspace restore에는 editor 원문을 넣지 않는다. dirty buffer recovery는 별도 local-only journal 또는 native shadow checkpoint로 설계한다.
- recovery record는 `document_id`가 아니라 root의 익명화 가능한 identity, 상대 경로, base fingerprint, editor revision, content 또는 edit log, schema version을 가진다.
- 주기/최대 용량/보존 기간/정상 save 후 삭제/web-content crash 후 복원/app crash 후 안내를 정의한다.
- journal은 source code·token을 포함할 수 있으므로 fixture나 일반 trace에 원문을 복제하지 않는다. 권한 mode, backup exclusion, purge UX를 검증한다.
- recovery가 base fingerprint와 맞지 않으면 자동 덮어쓰기하지 않고 recovered-vs-disk 비교를 연다.
- native가 canonical text를 상시 갖지 않는 구조에서 recovery checkpoint까지 없으면 WKWebView process crash가 dirty buffer를 전부 잃는다. 따라서 E2 편집 기능은 journal/shadow 중 하나가 실제 crash restore를 통과하기 전 완료 처리하지 않는다. 복구 저장을 원하지 않는 정책이면 E1 read-only까지만 제공한다.

## 5. 파일 I/O와 감시

### 5.1 safe-save

기존 `createFileAtomic(.replace=true,.make_path=true)`를 직접 재사용하지 않는다. editor 전용 저장은 다음 순서를 만족해야 한다.

1. grant root를 열린 directory descriptor로 고정하고 상대 path segment를 descriptor-relative로 순회한다. 문자열 `canonicalize → 검사 → 다시 path로 open`하는 TOCTOU 구조는 사용하지 않는다.
2. expected disk fingerprint를 비교한다.
3. 같은 디렉터리에 `O_EXCL` temp를 만들고 정상 save에서는 parent 자동 생성을 금지한다.
4. 기존 mode를 보존하고 ACL/xattr 보존 정책을 명시한다. 보존 실패는 조용히 무시하지 않는다.
5. write-all, file flush/fsync, atomic rename, directory fsync 순으로 완료한다.
6. 오류·취소 시 temp를 정리하고 원본을 유지한다.

경로 순회는 각 segment에서 symlink 정책을 강제하고, 검사 뒤 공격자가 symlink/parent를 교체하는 race를 red test로 둔다. hard link는 in-place write면 root 밖 같은 inode까지 바꾸고 atomic replace면 기존 link 관계를 끊으므로, v1에서 link count>1 저장을 거부할지 사용자 확인할지 결정한다. file type은 regular file만 허용하고 device/FIFO/socket은 거부한다. ownership, mode, ACL, xattr, quarantine/backup metadata 중 무엇을 보존하는지 명시한다.

기존 파일 저장과 새 파일 생성은 같은 op로 암묵 처리하지 않는다. `file.save`는 이미 열린 document identity만 갱신하고, `file.create`는 별도 확인·충돌 검사·기본 mode·부모 존재 조건을 가진다. rename/delete도 E2 기본 범위에 넣지 않고 별도 capability/UX가 정해질 때까지 거부한다.

최소 테스트: 기존 mode/ownership, 새 파일, 내부·외부 symlink, symlink swap race, parent rename race, hard link, 특수 파일, read-only dir, xattr/ACL 정책, disk-full/short-write 주입, fsync/rename 실패, temp cleanup, CAS 충돌, save 중 추가 편집.

### 5.2 외부 변경 감시

L4 macOS host가 open document를 디렉터리별로 묶어 `DispatchSource` 또는 규모가 커질 때 FSEvents로 감시한다. 기존 PTY kqueue 구현은 lifecycle/threading 참고만 하고 file watcher로 일반화해 억지 재사용하지 않는다.

- event를 debounce/coalesce한 뒤 그 directory의 열린 문서를 모두 재-stat/hash한다.
- rename/delete로 directory watch 자체가 무효화되면 re-arm한다.
- watcher 이벤트 종류나 횟수는 정합성 authority가 아니다.
- close/revoke/workspace 변경 때 watch와 in-flight hash를 취소한다.
- v1은 directory watcher 수에 hard cap을 두고 초과 시 명시적으로 기능을 제한한다. FSEvents 전환은 실제 cap 압력이 측정될 때 후속으로 둔다. sleep/wake, volume unmount, case-only rename, rapid replace storm 뒤에도 최종 hash로 수렴하는 soak는 유지한다.

## 6. bounded diff/git API

전체 저장소의 before/after blob을 한 응답에 싣는 `diff.read`는 사용하지 않는다.

- `diff.list`: `{path, old_path?, status, binary, before_size, after_size, hunk_summary?}` metadata를 pagination해서 반환한다.
- `diff.list` 첫 응답은 `diff_snapshot_id`와 stable cursor를 발급한다. pagination 중 index/worktree가 바뀌면 서로 다른 시점의 목록을 섞지 않고 `stale_snapshot`으로 다시 시작하게 한다.
- `diff.open`: `{diff_snapshot_id, path}`로 한 파일의 original/modified를 명시적 byte 상한 안에서 반환한다. 너무 크거나 binary면 typed `too_large`/`binary` 결과와 external-open fallback을 준다.
- UI bridge와 외부 socket은 같은 의미 DTO를 쓰되 각각의 transport 상한 안에서 chunk/page한다.
- `git.stage`/`unstage`는 저장·conflict 모델이 안정된 후 별도 write capability로 추가한다.
- `git discard`는 파괴적이고 복구 의미가 달라 초기 roadmap에서 제외한다. 후속으로 하더라도 명시 확인·복구 경로를 별도 설계한다.

상한은 raw blob뿐 아니라 UTF-8 decode와 JSON escape 뒤 전송 bytes, 파일 수, hunk 수, line length를 각각 센다. 압축/escape 전 크기만 검사해 메모리 증폭을 허용하지 않는다.

Git read도 workspace 내용을 노출하므로 `git_read` grant 없이는 허용하지 않는다.

Git 의미와 실행 안전도 E1 전에 고정한다.

- 비교 기준을 `HEAD↔index`, `index↔worktree`, `HEAD↔worktree`로 명시하고 staged/unstaged/untracked를 한 상태로 뭉개지 않는다.
- rename/copy, type change, mode-only change, symlink blob, deleted file, unmerged conflict(stage 1/2/3), submodule gitlink, empty/unborn repository를 typed status로 표현한다.
- `.git` directory뿐 아니라 worktree의 `.git` file과 bare/unborn 상태를 처리한다. 현재 sidebar branch 탐색의 best-effort 구현을 diff root 탐색에 재사용하지 않는다.
- `GitAdapter`는 shell이나 사용자 alias를 거치지 않고 승인된 git executable을 argv로 직접 실행한다. executable path/version을 기록하고 PATH hijack, pager/editor prompt, credential/network 접근이 없는 read-only 명령만 `git_read`로 허용한다.
- read-only diff 호출은 repository config가 외부 프로세스를 실행하지 못하도록 external diff/textconv/pager와 interactive prompt를 명시적으로 끈다. config·attributes·filter가 실행되는 각 명령을 adversarial repo fixture로 확인한다.
- git stderr에는 path/user/repo 정보가 있으므로 raw로 page/trace에 전달하지 않는다.
- 이후 stage/unstage는 clean/smudge filter, index lock, partial hunk stale context를 별도 보안·CAS 문제로 다룬다.

## 7. 빌드·Monaco·CSP gate

### 7.1 툴체인

- self-host asset만 사용하고 CDN은 금지한다.
- **UI 프레임워크를 도입하지 않는다.** editor/git diff는 [file-panel.md](file-panel.md) §2.1이 이미 확정한 **vanilla TS 웹앱 스택**을 공유한다(React/Svelte 런타임은 반응형 트리·라우팅이 없는 이 표면에 과하다 — file-panel §2.1의 근거 그대로). Monaco/CM6·remark류는 프레임워크가 아니라 **DOM 마운트 라이브러리**라 이 결정과 직교한다.
- **에디터 엔진은 file-panel과 정합해야 한다(미결).** file-panel은 CM6를 이미 확정했고(마크다운 SSOT·한글 IME가 WebKit 네이티브 위에서 가장 안정·sanitize 파이프 공유), 이 문서는 Monaco를 후보로 뒀다. 그런데 **§1·§7.4의 Monaco WKWebView RED가 정확히 file-panel이 CM6를 고른 이유(WebKit 렌더·한글 IME)와 겹친다.** git diff 뷰는 Monaco DiffEditor가 강점이지만, 채택 결정은 §7.4 gate와 file-panel 정합(§10)에 종속된다. **Monaco가 RED로 남으면 CM6 + diff/merge extension을 같은 gate로 비교한다.**
- Monaco를 쓸 경우 barrel 대신 `editor.api`와 실제 지원 언어 contribution만 import한다.
- worker URL은 정적 literal로 배선하고 output asset/worker manifest를 검증한다.
- zntc 최소 버전은 `16f1fda...`의 Monaco 수정이 포함된 릴리스가 나온 뒤 고정한다. 그 전 commit pin은 의존성/재현성 결정을 사용자에게 먼저 보고한다. (엔진이 CM6로 확정되면 Monaco 전용 zntc 수정 의존은 해소된다 — CM6는 file-panel이 이미 번들 중.)

Monaco를 쓸 경우 새 JS toolchain은 아직 프로젝트 의존성으로 승인된 것이 아니다. Phase 0.5A가 green이어도 의존성·license·bundle/RSS 측정 승인을 거쳐야 Phase 1에 들어간다.

### 7.2 CSP

`script-src 'unsafe-eval'`이나 remote source는 열지 않는다. 그러나 현재 Monaco는 WebKit PoC에서 inline style을 사용했다. 가능한 선택은 다음 둘이며 Phase 0.5A에서 결정한다.

1. **권장 후보:** editor origin에만 `style-src 'self' 'unsafe-inline'`을 허용하고 markdown/browser 정책은 유지한다. style 완화가 script 실행 권한으로 번지지 않는지 adversarial fixture로 고정한다.
2. Monaco style injection을 제거/nonce화할 수 있는 지원 경로를 찾아 엄격 style CSP를 유지한다.

전역 `csp_header` 하나로 editor 때문에 markdown 정책을 약화하지 않는다. editor별 CSP가 불가능한 현재 구조라면 `.editor` kind/asset resolver와 함께 먼저 분리한다.

### 7.3 필수 semantic oracle

각 프런트 빌드의 자동 gate는 다음이다.

1. 산출물 재파싱과 asset/worker 누락·404 검사
2. module evaluation과 CSP violation 0 검사
3. Monaco semantic probe: model text, tokenization, diff line/character decoration, marker, worker roundtrip
4. request/result 크기와 worker/process cleanup 검사

Vite는 개발/비교 기준일 뿐 제품 runtime에 포함되지 않는다. Chromium도 제품에 추가하지 않는다. zntc↔Vite pixel 1:1 비교는 릴리스 qualification이나 디버그 artifact로만 사용하며 모든 PR의 필수 gate로 두지 않는다.

### 7.4 제품 WKWebView gate

Phase 0.5A 종료 조건은 실제 Maru `WKWebView`, `maru-app://`, editor CSP, 제품 asset resolver로 다음을 자동/수동 artifact와 함께 통과하는 것이다.

- editor text가 non-zero layout으로 실제 표시되고 screenshot에 포함됨
- caret/selection, ASCII insert/delete, undo/redo
- 한글 조합 중 preedit, 완성, NFD 입력 fixture, caret 이동, backspace/delete
- paste/copy, find, `Cmd+S`, Maru 전역 shortcut과 Monaco shortcut 충돌, first-responder 이동
- resize, backing scale, theme 전환, hide/show와 tab/window 이동 뒤 model·selection 보존
- module worker, diff decoration, marker, syntax token
- page-world editor bridge allowlist, markdown/browser에서 bridge 부재
- CSP violation/console error/404 0, close/reload/crash 후 worker와 pending request 정리

E0.5A PR은 계획 명령 `mise run test-macos-editor-smoke`와 display opt-in `mise run macos-editor-smoke`를 실제 `.mise.toml`/development-commands에 추가한다. artifact는 `zig-out/maru-macos-editor-smoke/` 아래 최소 `editor.summary.txt`, `editor-dom.json`, `editor-snapshot.png`를 남긴다. summary는 engine/build identifier, CSP violations, console errors, worker count, text/caret/edit/IME/cleanup 결과를 machine-readable key로 기록한다. DOM artifact는 크기·role·상태만 담고 source text는 넣지 않으며, screenshot은 저장소의 synthetic fixture만 사용한다. 기존 Metal PPM은 WKWebView pixel을 포함하지 않으므로 WebKit `takeSnapshot` 또는 동등한 WKWebView snapshot 경로를 사용한다.

IME는 synthetic JS/AppKit event만으로 통과 처리하지 않는다. 자동 하니스는 DOM/model 상태를 고정하고, 종료 gate에는 실제 macOS 한글 입력기로 preedit→완성→caret→backspace를 수행한 수동 summary를 함께 요구한다.

현재 이 gate는 **RED**다. 실패 원인을 WebKit 지원 문제, custom-scheme origin/worker 문제, CSS/layout 문제, 하니스 문제로 좁히기 전 Monaco 경로를 “가능”으로 확정하지 않는다. 해결되지 않으면 CodeMirror 6 등 대안을 같은 gate로 비교한다.

## 8. 포맷·린트·LSP

### 8.1 workspace tool execution

formatter/linter와 LSP는 모두 저장소의 config/plugin/binary를 실행할 수 있다. `tool_execute`가 없는 workspace에서는 자동 실행하지 않는다.

- trusted workspace 확인과 도구별 allowlist/해결된 executable 표시
- shell 없이 argv 실행, canonical cwd=root, 최소화한 environment
- timeout, stdout/stderr byte 상한, child/process-group 상한, cancellation/kill/reap
- config discovery 결과와 실제 executable/version을 사용자 및 trace에 노출
- 포맷 결과는 곧바로 저장하지 않고 현재 revision에 대한 text edits로 반환
- tool이 root 밖 파일을 읽거나 쓰는 것을 OS 수준에서 sandbox하지 못하는 초기 버전의 한계를 확인 UX에 명시

포맷/린트를 “LSP보다 가볍다”는 이유로 보안 단계를 앞당기지 않는다. 필요성이 확인되면 저장 Phase 뒤 선택적으로 연다.

### 8.2 LSP seam

LSP는 다음 최소 seam만 요구한다.

- `didOpen/didChange/didSave/didClose`로 매핑 가능한 document revision event
- Content-Length framing을 control-plane ndjson과 분리한 transport
- server request/notification/response correlation, cancellation, restart/backoff
- diagnostic/completion/hover/definition/semantic-token의 bounded push
- workspace tool execution grant
- server→client `workspace/applyEdit`, `workspace/executeCommand`, file create/rename/delete, `window/showDocument`, 임의 URI open은 기본 거부하고 method별 사용자 승인/allowlist를 둔다.
- diagnostics/result에 root 밖 URI가 들어오면 표시와 파일 접근 권한을 분리한다. URI를 받았다는 이유로 grant가 확대되지 않는다.

TextMate, git staging, formatter는 LSP의 선행 조건이 아니다. 초기 syntax는 Monarch로 시작하고 LSP semantic token이 부족하다는 측정이 있을 때만 TextMate/WASM을 재검토한다.

### 8.3 관측 가능성과 민감정보

editor event는 처음부터 하나의 domain schema를 공유하되 문서 원문을 기본 trace에 넣지 않는다.

- 최소 event: `editor.opened`, `editor.changed`(revision/byte count만), `editor.save-started`, `editor.save-completed`, `editor.conflict`, `editor.watch-invalidated`, `editor.tool-started/completed`, `editor.bridge-overflow`.
- path는 grant-relative 또는 익명화한 값만 artifact에 남기고 capability, full text, diff blob, diagnostic message 원문, tool stdout/stderr는 기본 제외한다.
- control-plane/bridge event를 trace에 넣는 PR은 먼저 [facade-contracts.md](facade-contracts.md)와 [trace-replay.md](trace-replay.md)의 event/redaction/replay 의미를 갱신한다.
- failure artifact를 fixture로 승격할 때 [project-rules.md](project-rules.md)의 공통 redaction guard를 사용한다. source code에 token이 bare text로 들어갈 수 있어 자동 guard만으로 충분하다고 간주하지 않고 사람 검토를 요구한다.
- E2E artifact는 semantic summary와 redacted screenshot을 기본으로 하고, 실제 사용자 repository를 자동 캡처하지 않는다.

## 9. 단계 계획과 종료 gate

기존 [control-plane.md](control-plane.md)의 Phase 7 웹 toolchain/markdown 계획과 번호가 충돌하지 않도록 editor는 `E` prefix를 쓴다. 구현 PR 하나가 단계 전체를 끝내는 것을 기본값으로 보지 않는다.

### E0.5A — 제품 WebKit feasibility (현재 RED)

- committed editor smoke asset/harness, debug-only 전용 origin/CSP 실험. 사용자 승인 전 production `PanelKind`/ABI/wire는 바꾸지 않는다.
- Monaco와 비교 후보를 동일 gate로 실행
- text/caret/edit/IME/worker/diff/marker/cleanup artifact
- 1/2/4 editor surface에서 web-process RSS, worker 수, hidden/background CPU와 close 뒤 회수 측정
- **종료:** §7.4 전부 green + dependency/bundle/RSS·surface resource scaling 보고. 실패하면 Monaco 채택 중단 또는 대안 선택.

### E0.5B — 순수 계약

- `EditorGrant`, versioned bridge protocol/error/cancel/epoch, DTO size/page limits
- app-global DocumentState, multi-surface 구독, revision/CAS 상태머신
- encoding/newline model, descriptor-relative path policy, safe-save failure injection, directory watcher policy 단위 테스트
- dirty recovery의 journal 대 native shadow 선택과 schema/redaction/보존 정책
- **종료:** 구체적인 상한 숫자와 파일 포맷 지원 범위를 포함해 UI 없이 auth/path/revision/save/watch/recovery 불변식 green.

### E1 — web toolchain + read-only diff

- 승인된 zntc/Monaco 버전 pin과 reproducible build
- `.editor` surface/asset/CSP/bridge, `diff.list`/`diff.open`
- semantic oracle + 제품 WKWebView regression
- git comparison/status matrix와 external diff/textconv 실행 차단
- **종료:** grant root 밖 접근·큰 파일·binary·rename·worktree `.git` file·untracked/conflict/submodule·close/revoke를 포함한 read-only review loop green.

### E2 — 편집·저장·외부 변경

- DocumentRegistry, editor change event, safe-save CAS
- directory watcher, clean reload, dirty conflict UX
- **종료:** 동일 파일 재오픈 focus/read-only/owner-transfer, save 중 재편집, 외부 atomic replace, symlink swap/hard-link, encoding/newline 보존, mode/ownership/xattr 정책, 실제 web-content/app crash recovery restore/purge green.

### E3 — 선택적 도구 실행

- formatter/linter registry와 explicit trust UX
- timeout/output/process cleanup, edit application
- **종료:** 악성 config fixture와 취소/폭주/종료 cleanup green.

### E4 — LSP

- transport/supervisor와 document sync
- diagnostics부터 vertical slice, 이후 completion/hover/definition/semantic token
- **종료:** stale response, restart, cancellation, large diagnostics/backpressure, workspace revoke green.

### 후속 backlog

- git stage/unstage, 파괴적 discard UX
- TextMate/WASM
- 증분 대형 문서 전송과 virtualized diff
- 다중 root·동시 여러 repository, remote/SSH workspace. 단일 linked worktree의 `.git` file 처리는 E1 범위다.

## 10. 구현 전 사용자 결정

다음은 문서만으로 승인된 것으로 간주하지 않는다.

0. **[file-panel.md](file-panel.md)와의 정합 — 가장 상위 결정.** git diff·editor를 (a) 파일 패널 도크의 새 콘텐츠 kind로 넣을지, (b) 별도 `.editor` surface로 둘지. 사용자 방향은 "마크다운 뷰어와 동일 레이아웃"이라 (a)로 기운다. (a)면 이 문서의 `.editor` 전용 kind/origin/bridge 상당 부분이 파일 패널 shell·`maru.file.*` 채널 위 **확장**으로 재작성된다.
0b. **에디터 엔진 CM6 대 Monaco.** file-panel은 CM6 확정(§7.1). Monaco는 §7.4 WKWebView gate가 RED. git diff는 Monaco DiffEditor가 강하나, RED가 안 풀리거나 도크 정합을 택하면 **CM6 + diff/merge extension**이 유력하다. 이 결정이 §7.1·§7.4·본 §10의 여러 하위 항목(zntc 의존·CSP inline style·번들/RSS)을 연쇄로 바꾼다.
1. `PanelKind.editor`와 ABI/wire 확장 (0에서 (b)를 택할 때만)
2. Monaco 및 zntc 의존성, 수정 포함 릴리스 대기 대 commit pin (0b에서 Monaco를 택할 때만)
3. editor origin 한정 `style-src 'unsafe-inline'` 허용 여부
4. 최초 workspace/file/git grant UX와 native `root_id`/root descriptor 발급·회수
5. 새 파일의 기본 mode 및 기존 ownership/ACL/xattr/hard-link 보존·거부·실패 정책
6. 최초 지원 파일 크기·diff page·bridge/socket payload 상한
7. v1 지원 encoding/BOM/mixed-newline 정책과 binary/invalid UTF-8 UX
8. 동일 파일을 여러 surface에서 여는 UX와 app-global document session 공유 방식
9. dirty recovery의 journal 대 native shadow, 기본 활성/opt-out UX, 최대 용량, 보존 기간, purge UX
10. git diff 기준(HEAD/index/worktree) 기본값과 untracked/conflict/submodule 표시 범위

## 11. 현재 한계

- **이 문서는 [file-panel.md](file-panel.md)와 아직 완전히 정합되지 않았다.** 파일 패널은 도크 레이아웃·CM6·vanilla 스택·핀 파일 read/write를 이미 확정했고, git diff/editor는 그 위 확장으로 재작성될 가능성이 높다(§10.0). 아래 Monaco 관련 한계는 그 정합에서 CM6를 택하면 상당수 소멸한다.
- 제품 WKWebView에서 Monaco의 텍스트 표시·편집·IME는 아직 실패/미검증이다.
- 임시 PoC 하니스와 결과 artifact가 저장소에 없으므로 재현성은 E0.5A가 닫아야 한다.
- zntc current main 성공은 릴리스/장기 재현성을 보장하지 않는다.
- safe-save는 요구사항만 검증됐고 구현되지 않았다.
- 제품 file capability 발급, editor bridge, DocumentRegistry, watcher, diff service는 모두 미구현이다.
- bundle size 외 실제 WKWebView web-process RSS, first interactive, large-file latency 예산은 미측정이다.
- 파일 encoding/newline, multi-surface 동시 편집, crash recovery, hard-link/TOCTOU, git worktree/conflict 의미는 이번 문서에서 구현 gate로 추가됐지만 아직 PoC가 없다.
- editor domain event/trace schema와 민감정보 artifact 형식은 미정이며 E0.5B에서 facade/trace 문서와 함께 닫아야 한다.
