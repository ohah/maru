# 에디터 Surface — 권장 구조 (§3~§3.4)

우측 도크(목록)와 파일 Term(본문)이라는 배치, kind와 trust 경계, 브리지 확장·grant·프로토콜, 예상 코드 배치의 계약이다. 도크가 **어떻게 보이는지**는 [도크 소스 컨트롤 뷰](editor-surface-dock.md)가 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§3.5`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1·§2·§4·§5·§10·§11 [editor-surface.md](editor-surface.md) · §3~§3.4 [권장 구조](editor-surface-structure.md) · §3.5 [도크 소스 컨트롤 뷰](editor-surface-dock.md) · §6~§8 [diff·빌드·LSP](editor-surface-tooling.md) · §9 [단계 계획](plans/editor-surface.md)

## 3. 권장 구조 — 우측 도크(목록) + 파일 Term(본문)

**editor/git diff는 별도 surface를 새로 만들지 않고 [file-panel.md](file-panel.md)가 이미 가진 두 자리를 쓴다.** FP16 이후
그 두 자리는 이렇게 갈린다.

- **변경 목록·스테이징 UI = 우측 도크의 새 뷰**(Zig + GPU chrome). 탐색기 트리와 같은 컬럼을 공유하고 상단 아이콘 줄로
  전환한다(§3.5). 웹뷰가 아니다.
- **diff 본문 = 파일 `Term`**(**네이티브 등폭 GPU 뷰** — 2026-08-09 개정, §1.1. 옛 서술은 "WKWebView + CM6 `MergeView`").
  마크다운 문서가 그러하듯 탭 스트립에 살고, 터미널 옆에서 같은 split·드래그·닫기 계약을 그대로 쓴다. 본문의 렌더·매핑
  계약은 [native-editor.md](native-editor.md)가 소유한다.

이 분할은 새 정책이 아니라 **FP16을 그대로 따른 결과**다. 도크는 "여러 파일을 훑는 세로 컬럼", Term은 "지금 보는 문서"이고,
git 리뷰는 정확히 그 두 역할로 나뉜다. 초판이 상정한 "도크 콘텐츠 rect에 diff 웹앱을 얹는다"는 도크에 콘텐츠 rect가
없어졌으므로 성립하지 않는다.

```text
우측 도크 ── 창(chrome) 레벨, Zig + GPU, 폭 조절·접기 ────────
  뷰 스위처(아이콘 줄)  탐색기 | 소스 컨트롤 | (후속: 확장·작업)
  ├ 탐색기 뷰 = 파일 트리                    (file-explorer.md 소유)
  └ 소스 컨트롤 뷰 = 브랜치·커밋 메시지·변경 목록  (§3.5, 이 문서 소유)
       diff.list / git.status 결과를 **직접** 소비한다(웹 경유 없음)

워크스페이스 pane 트리 ── 탭 스트립 공유 ─────────────────────
  터미널 Term · 브라우저 Term · 파일 Term
  파일 Term(diff kind) = **네이티브 등폭 GPU 뷰**(2026-08-09 개정 · native-editor.md)
    in-process 직접 호출 — WKWebView·origin·브리지를 거치지 않는다
       editor.* / diff.* / git.*             ← L2 코어 직접 호출(경로 스코프는 내부 불변식, §1.1)

  파일 Term(markdown kind) = WKWebView, 두 web 컨텍스트(file-panel §2.1) — 개정 대상 아님:
    ├ 격리 렌더 origin  = 새니타이즈 md/rich-render(Mermaid 등). 브리지 없음.
    └ 신뢰 shell origin = CM6 마운트 + 브리지 + 오케스트레이션
         maru.file.read()/write(content)     ← file-panel: **핀 경로** read/write

신뢰 shell 브리지(확장) ── in-process, host가 surface에 결합한 grant 검증 후 직접 호출
  -> L2: file-panel 정책 + editor 코어(신규)
       |- DocumentRegistry (identity/revision/disk fingerprint/conflict/recovery)
       |- EditorGrant/path scope  (핀 단일 경로 → grant-root 상대 = 의도적 escalation, §3.2)
       |- diff/turn-base model (§6·§6.1)
       `- injected adapter interfaces
            |- L4 FileAdapter (descriptor-safe read/save/stat/hash)
            |- L4 WatchAdapter (DispatchSource/FSEvents)
            |- L4 GitAdapter (bounded read-only git invocation)
            `- L4 ToolAdapter (formatter/linter/LSP process)

external CLI/agent
  -> Unix socket + capability nonce
  -> 같은 L2 policy/services
```

**재사용 vs 신규(정합 — 2026-08-09 엔진 개정 반영):** 도크 컬럼·폭/접기·파일 Term 호스팅·dirty 보고는 **file-panel이 이미
가졌다**(재사용). editor가 신규로 짓는 것은 ⑴ L2 editor 코어(grant·registry·CAS·diff/turn model), ⑵ 그것을 부르는 **in-process
호출부**, ⑶ **도크 소스 컨트롤 뷰 chrome**(§3.5), ⑷ **네이티브 등폭 뷰**([native-editor.md](native-editor.md))다.
별도 `.editor` PanelKind를 만들지 않는다.

~~두 web 컨텍스트·CM6 마운트·`maru.file.*` 브리지 트랜스포트 재사용, 브리지 method 확장(diff/git/multi-file/save), 별도
origin·별도 브리지 금지~~ → **diff·코드 편집 축에서 소멸**(§1.1). 웹 컨텍스트를 지나지 않으므로 재사용할 트랜스포트도,
넓힐 브리지 method도, 금지할 새 origin도 없다. 이 서술들은 **마크다운 축에서는 계속 유효**하다(file-panel 소유).

**목록이 웹이 아닌 이유.** 아키텍처 B(“chrome은 Zig+GPU, WKWebView는 콘텐츠만” — [file-panel.md](file-panel.md) §1)를 그대로
따른다. 변경 목록은 트리·탭·사이드바 카드와 같은 계열의 chrome이고, 이미 GPU로 그리는 탐색기 트리 바로 위에 얹힌다. 목록을
웹앱으로 만들면 같은 컬럼 안에 GPU chrome과 웹 chrome이 섞여 룩·포커스·히트테스트가 이중이 된다. 대신 diff **본문**은 텍스트
편집기가 필요하므로 웹(CM6)이 맞다 — 경계는 “문서 내용이냐 아니냐”다.

제품 UI 요청을 자기 Unix socket으로 되돌려 보내지 않는다. socket 인증은 외부 프로세스 경계용이고, in-process bridge는 host가 surface에 결합한 grant를 검증한 뒤 같은 L2 dispatcher를 직접 호출한다. 이 구분으로 payload 복사·deadlock·자기 인증 우회를 피한다.

L2는 file descriptor, DispatchSource, FSEvents, child process, AppKit/WebKit 타입을 몰라야 한다. grant 판정·문서 상태·CAS 전이·DTO/error mapping은 `src/session/`의 순수 코어가 소유하고, 실제 파일·git·watch·process I/O는 `src/app` 공통 runtime 또는 `src/platform/macos` adapter가 주입한다. `check-boundaries`에 editor 코어의 platform import 금지를 추가한다.

### 3.1 kind와 trust 경계

**형태는 (a′)로 좁혀졌다**(§10.0) — 목록은 도크 뷰, 본문은 diff kind **파일 Term**이다. 따라서 이 절이 정하는 것은 새 surface
종류가 아니라 **파일 entry kind 하나**와 그 kind에 붙는 grant다.

- 파일 entry의 `EntryKind`([file-panel-kinds.md](file-panel-kinds.md) §2)에 `diff`를 additive로 더한다. 새 top-level `PanelKind`가 아니다 —
  FP16이 확인했듯 `PanelKind`는 `{markdown, browser}` 2값 = trust/config 선택자이고, 값을 더하면 Swift의
  `let trusted = (panelKind == 0)` 파생이 조용히 깨진다. `diff` kind는 `.markdown`(신뢰 shell)으로 파생한다.
- 목록 UI는 web이 아니라 GPU chrome이라 origin/CSP 결정이 아예 없다(§3).
- 별도 `.editor` surface(옛 (b)안)는 만들지 않는다. 되살릴 이유가 생기면 §10.0을 먼저 뒤집는다.

어느 쪽이든 아래 trust 경계는 동일하게 적용한다.

**정정: 마크다운 뷰어도 파일시스템을 만진다.** [file-panel.md](file-panel.md)의 파일 패널은 `.md`/`.html`을 `loadFileURL(allowingReadAccessTo:)`로 **읽고**(디렉터리 스코프), 열린 핀 경로 하나에만 `maru.file.write`로 **쓴다**(§3, write 스코프=열린 파일만). 즉 markdown은 "표시 전용/파일시스템 0"이 아니라 **경로가 고정된 읽기 + 좁은 쓰기**다. 여기서 진짜 신뢰 경계는 read/write 유무가 아니라 **범위**다.

신뢰 등급(범위 기준):

- **마크다운 뷰어(file-panel)**: 핀 파일 read(+ 좁은 write). 파일별로 열 때 확정, JS가 확대 불가.
- **read-only git diff**: 파일 write 없음. worktree/HEAD blob **read** + bounded `git_read`. → 신뢰 수준이 full editor보다 마크다운 뷰어에 가깝다.
- **editor(편집)**: 여기서 `file_write`가 붙는다. 이게 계단의 실제 단차다.

그러므로 **editor 파일 write op를 markdown/뷰어 route에 얹지 않는다**(범위 확대 금지). `browser`는 계속 untrusted이며 editor bridge와 `maru-app://` asset에 접근하지 못한다.

**레이아웃은 공유, trust는 분리(사용자 방향).** git diff·editor는 [file-panel.md](file-panel.md)의 전역 도크와 **동일한 시각 shell**(탭 스트립·헤더 밴드·파일 트리 = GPU chrome, 콘텐츠 rect = WKWebView)을 공유해 UX 일관성과 코드 재사용을 얻는다. 실제로 git diff는 도크의 **또 다른 콘텐츠 kind**(현행 `.md`/`.html` 옆)로 보는 게 자연스럽다. **다만 레이아웃 재사용이 trust 재사용을 뜻하지 않는다** — 같은 도크 안에서도 kind별 origin/CSP/grant는 위 계단대로 분리한다. 엔진은 **네이티브 등폭 GPU 뷰로 개정**됐고(§1.1 — 옛 서술 "CM6로 확정"), 도크 정합(a/b)만 §10.0 결정 항목이다. 이 문단의 "콘텐츠 rect = WKWebView"도 diff 본문 축에서는 개정 대상이다.

**origin 공유의 함정**: diff 파일 Term이 markdown 파일 Term과 같은 `maru-app://app` origin·같은 신뢰 shell 브리지를 공유하므로, **origin pin만으로는 "이 요청이 diff 리뷰냐 md 뷰어냐"를 구분할 수 없다**. 그래서 브리지 method가 `EditorGrant`를 요구하고, 그 grant는 native가 **그 파일 Term(surface_id)에 결합**한다 — md 뷰어 Term에는 `file_write`/`git_read`가 없고 diff/editor Term에만 있다. 즉 권한 구분은 origin이 아니라 **entry별 grant**가 한다. main frame + 신뢰 origin + top-level navigation 거부는 그대로 강제하고, md asset route로 이동해도 editor grant가 따라붙지 않게 한다.

### 3.2 브리지 확장과 grant — 핀 경로에서 grant-root로

editor는 file-panel의 **신뢰 shell origin 브리지를 그대로 쓴다** — editor op는 그 브리지의 **새 method**이고, 정책은 file-panel과 동일하게 Zig(L2)가 판정한다(control_bridge 현행 표면=`hello` 1개, 나머지는 전부 신규 — file-panel과 공유하는 신규 계약).

**미결(공유 결정 — file-panel FP4가 정한다)**: 현행 브리지는 **isolated `WKContentWorld` 전용**이고 page-world `window.maru`는 의도적으로 없다(§2). 그런데 CM6 웹앱이 브리지를 부르려면 ① 앱 JS를 isolated world에 태우거나(DOM은 공유되므로 CM6 마운트 가능) ② 신뢰 shell 문서에 한해 좁은 page-world shim을 노출해야 한다. §1 표의 PoC는 ②를 권장했다(기록). 이 선택은 file-panel `maru.file.read` 배선(FP4)이 처음 맞닥뜨리는 **공유 결정**이라 editor가 단독으로 정하지 않고 그 결과를 따른다 — 두 경우 모두 아래 grant 규칙은 동일하다.

**핵심 escalation**: file-panel의 `maru.file.*`는 **경로 인자가 없다** — 파일 Term을 열 때 핀된 **단일 경로** 하나에만 read/write한다(웹앱이 경로를 못 고르는 게 안전장치). 그런데 git diff 리뷰·편집은 **변경 세트의 여러 파일**을 열고 그 안에서 write해야 하므로, editor는 핀-단일-경로를 **`EditorGrant`(grant-root + 상대 경로)**로 넓힌다. 이게 §3.1 신뢰 계단의 실제 단차이며, 넓힌 만큼 경로 안전 규칙(아래)을 강제한다.

`EditorGrant`는 JS가 고르는 bearer nonce가 아니라 native host가 diff/editor **파일 Term** 생성 시 결합하는 리소스 권한이다.

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

### 3.3 브리지 프로토콜과 생애주기

file-panel 브리지의 editor method도 임의 JS 객체 호출이 아니라 버전 있는 protocol로 고정한다(file-panel `maru.file.*`와 같은 규율을 공유하되, editor는 다중 파일·grant-root라 request가 무거워 상한·취소·epoch를 명시한다).

```text
EditorRequest {
  protocol_version,
  request_id,
  surface_id,
  method,       // file.open / file.save / diff.list / diff.open / git.* …
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

### 3.4 예상 코드 배치 — L2 코어는 신규, 웹앱·브리지는 file-panel 확장

editor **L2 코어**(정책·상태)는 신규 파일로 나눠 `app_session.zig`/`MaruAppHost.swift` 재누적을 막되, **웹앱·브리지·도크 chrome은 file-panel 코드를 확장**한다(별도 트리를 새로 만들지 않는다).

```text
신규 — editor L2 코어 (엔진·플랫폼 무관)
  src/session/editor/
    protocol.zig           version/error/DTO/limit
    grant.zig              EditorGrant/path scope policy (핀→grant-root escalation)
    document_registry.zig  revision/owner/conflict/recovery state
    diff_model.zig         stable snapshot/status DTO + turn-base(§6.1)
  src/app/
    editor_runtime.zig     adapter orchestration/cancel/queue
  src/platform/macos/
    editor_file.zig        descriptor-relative file adapter (safe-save §5.1)
    editor_watch.zig       DispatchSource/FSEvents adapter
    editor_tool.zig        git/tool/LSP process adapter

신규 — 도크 소스 컨트롤 뷰 chrome (§3.5)
  src/session/
    scm_view.zig           뷰 상태(섹션 접힘·선택·스크롤)·행 모델·순수 레이아웃 계산

확장 — file-panel 소유 코드에 method/kind 추가 (신규 병렬 파일 아님)
  file-panel 신뢰 shell 브리지  += editor.*/diff.*/git.* method + EditorGrant 검증
  ~~file-panel 웹앱(web/, React) += diff 뷰(CM6 MergeView)~~ → **네이티브 등폭 뷰**(§1.1 개정)
  file-panel 웹앱(web/, React)  += 턴 타임라인(마크다운 축)
  파일 Term entry kind(file-panel §2) += diff kind
  도크 뷰 스위처(file-explorer.md) += 소스 컨트롤 뷰
```

`src/session.zig`는 editor L2 facade만 export한다. 브리지 method를 더하는 Swift 변경은 file-panel 브리지 어댑터(현행 `MaruAppHost.swift`의 bridge handler — FP4에서 분리될 수 있음)에 얹는다. 그 파일은 `build.zig` swiftc·swift-check에 이미 연결돼 있어 빌드 배선 신규가 없다. 실제 디렉터리를 추가하는 PR은 [project-structure.md](project-structure.md)와 [file-panel.md](file-panel.md)(브리지 method 표)를 같은 PR에서 갱신한다. app-global `DocumentRegistry`의 runtime owner는 per-window `AppSession`이 아니라 전 창이 공유하는 `AppRuntime` 계층에 둔다 — file-panel 도크는 창 안에서 전역(워크스페이스 무관)이고 도크 모델은 창(세션) 소유이므로, **여러 창의 도크가 같은 파일을 열 때** identity를 하나로 묶는 건 창 위 계층이어야 한다.
