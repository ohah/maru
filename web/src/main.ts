import { bootRenderer, bootShell } from "./viewer";
import { bootDiff } from "./diff-view";

// WKWebView 기본 우클릭 메뉴(Reload·Inspect Element 포함)를 억제한다([web-panel.md] §8 "컨텍스트 메뉴"). 특히
// Reload는 편집 중 WebContent를 재시작해 editor recovery latch를 걸어 파일 작업을 차단한다. 여긴 maru-app 신뢰
// 콘텐츠(파일 패널 셸 app + 렌더 iframe render)만 로드하므로 브라우저 패널(외부 콘텐츠)에는 영향이 없다. 복사·
// 붙여넣기는 메뉴바/⌘ 단축키가 소유한다([web-panel.md] §4.2).
window.addEventListener("contextmenu", (event) => event.preventDefault());

// `?kind=diff`(E1)는 편집 shell이 아니라 읽기 전용 비교 화면이다 — read/write·dirty·⌘S 배관을 태우지 않는다.
if (
  window.location.host === "app" &&
  new URL(window.location.href).searchParams.get("kind") === "diff"
)
  bootDiff(document);
else if (window.location.host === "app") bootShell(document, window);
else if (window.location.host === "render") bootRenderer(document, window);
