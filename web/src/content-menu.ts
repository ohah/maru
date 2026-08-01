/**
 * 문서 영역 우클릭 → **메뉴는 native가 그린다**(docs/file-panel.md §2.6).
 *
 * 여기서 web이 하는 일은 둘뿐이다. ⑴ "어디서 우클릭했고 대상이 무엇인지"를 브리지로 올린다. ⑵ 그 메뉴에서
 * 고른 항목 중 **선택에 붙은 것**을 native가 되돌려 보내면 실행한다 — 선택 범위는 문서 안에 있어 native가
 * 모르기 때문이다.
 *
 * 그리기·키보드 이동·바깥 클릭 닫기·테마는 native가 이미 가진 메뉴 경로가 한다(터미널 본문·파일 트리·사이드바
 * ⚙가 쓰는 그 경로). 그래서 이 파일에는 UI가 없다.
 */

/** 렌더 iframe → shell 좌표 전달에 쓰는 메시지 타입(줌이 쓰는 채널과 같은 채널을 공유한다). */
export const contextMenuMessageType = "contextmenu";

export type MenuTarget = "text" | "link" | "image" | "empty";

export type MenuHit = {
  /** 우클릭 지점. 렌더 iframe에서 온 값은 shell이 iframe 오프셋을 더해 shell 뷰포트 좌표로 만든다. */
  x: number;
  y: number;
  target: MenuTarget;
  /** 링크 주소나 이미지 경로. 없으면 빈 문자열이다. */
  href: string;
};

/**
 * 우클릭 지점이 무엇 위였나. **가장 안쪽 요소부터 조상 방향으로** 링크·이미지를 찾는다 — 링크 안의 이미지를
 * 우클릭하면 사용자가 겨냥한 것은 보통 이미지이므로 안쪽이 이긴다.
 */
export function hitFromEvent(event: MouseEvent): MenuHit {
  const point = { x: event.clientX, y: event.clientY };
  const node = event.target;
  if (!isElement(node)) return { ...point, target: "empty", href: "" };

  const image = node.closest("img");
  if (image !== null) {
    // 렌더 origin의 이미지는 `src`가 data: URL로 바뀌어 있으므로 **원본 경로**(renderer가 남긴 메타데이터)를 쓴다.
    // 그게 없으면(편집기 안의 이미지 등) 빈 값으로 둔다 — 추측한 경로를 native에 넘기지 않는다.
    const assetPath = image.getAttribute("data-maru-asset-path") ?? "";
    return { ...point, target: "image", href: assetPath };
  }
  const anchor = node.closest("a[href]");
  if (anchor !== null) {
    return { ...point, target: "link", href: anchor.getAttribute("href") ?? "" };
  }
  return { ...point, target: "text", href: "" };
}

/**
 * Element인가. `instanceof`를 쓰지 않는다 — 이 코드는 shell과 렌더 iframe **두 realm**에서 돌고, 문서가
 * 건너온 노드는 다른 realm의 생성자를 갖는다(그러면 `instanceof Element`가 조용히 false가 되어 모든 우클릭이
 * 여백으로 접힌다). 구조로 판정하면 realm과 무관하다.
 */
function isElement(node: unknown): node is Element {
  return (
    typeof node === "object" &&
    node !== null &&
    typeof (node as Element).closest === "function" &&
    typeof (node as Element).getAttribute === "function"
  );
}

/** 마우스 이벤트인가(같은 이유로 구조 판정 — 좌표가 있어야 메뉴를 어디에 띄울지 정한다). */
function isMouseEvent(event: Event): event is MouseEvent {
  return (
    typeof (event as MouseEvent).clientX === "number" &&
    typeof (event as MouseEvent).clientY === "number"
  );
}

/**
 * 우클릭 **직전**의 선택. 브라우저는 우클릭의 기본 동작으로 선택을 접고 캐럿을 클릭 지점으로 옮기는데
 * (선택 밖을 눌렀을 때), 우리 메뉴는 native가 그리므로 사용자가 항목을 고르는 시점에는 이미 선택이 없다.
 * 그래서 **기본 동작이 일어나기 전**(mousedown capture 단계)에 붙잡아 둔다 — 복사·잘라내기가 볼 것은 이 값이다.
 */
export type SelectionSnapshot = { text: string; range: Range | null };

export const emptySelection: SelectionSnapshot = { text: "", range: null };

/**
 * 우클릭 직전 선택을 붙잡는 리스너를 건다. 반환값을 부르면 마지막으로 붙잡은 선택을 준다.
 *
 * **capture 단계**로 거는 것이 핵심이다. bubble 단계나 contextmenu 시점에는 브라우저가 이미 선택을 접었을 수
 * 있어, 그때 읽으면 빈 문자열을 복사하게 된다(실제로 그렇게 동작했다).
 */
export function installSelectionCapture(doc: Document): () => SelectionSnapshot {
  let snapshot: SelectionSnapshot = emptySelection;
  doc.addEventListener(
    "mousedown",
    (event) => {
      if (!isMouseEvent(event) || event.button !== 2) return;
      const selection = doc.getSelection();
      if (selection === null || selection.isCollapsed || selection.rangeCount === 0) {
        snapshot = emptySelection;
        return;
      }
      snapshot = { text: selection.toString(), range: selection.getRangeAt(0).cloneRange() };
    },
    true,
  );
  return () => snapshot;
}

/**
 * 접혀 버린 선택을 붙잡아 둔 값으로 되돌린다 — 메뉴가 떠 있는 동안 **사용자가 무엇을 겨냥했는지 계속 보이게**.
 * 선택이 살아 있으면 건드리지 않는다(사용자가 방금 만든 선택을 옛 값으로 덮지 않는다).
 */
export function restoreSelection(doc: Document, snapshot: SelectionSnapshot): void {
  if (snapshot.range === null) return;
  const selection = doc.getSelection();
  if (selection === null || !selection.isCollapsed) return;
  selection.removeAllRanges();
  selection.addRange(snapshot.range);
}

/** 문서에 **보이는** 선택이 있나. 접힌(collapsed) 선택은 캐럿일 뿐이라 복사·잘라내기 대상이 아니다. */
export function hasVisibleSelection(doc: Document): boolean {
  const selection = doc.getSelection();
  if (selection === null || selection.isCollapsed) return false;
  return selection.toString().length > 0;
}

/**
 * 렌더 origin(격리 iframe)에서 쓴다. **브리지를 부르지 않는다** — 이 origin은 capability 0이고, 자기가 화면
 * 어디에 있는지도 모른다(cross-origin). 로컬 좌표와 대상만 부모에게 넘기고 오프셋 보정은 shell이 한다.
 */
export function installRendererContextMenu(
  doc: Document,
  targetWindow: Window,
  channel: string,
): () => SelectionSnapshot {
  const snapshotOf = installSelectionCapture(doc);
  // 읽기 본문의 선택은 이 문서 안에 있다. shell이 "이제 명령을 보낸다"고 알리면 붙잡아 둔 선택을 되살린다.
  targetWindow.addEventListener("message", (event) => {
    const data = event.data;
    if (typeof data !== "object" || data === null) return;
    const record = data as Record<string, unknown>;
    if (record.channel !== channel || record.type !== "menuFocus") return;
    restoreSelection(doc, snapshotOf());
  });

  doc.addEventListener("contextmenu", (event) => {
    if (!isMouseEvent(event)) return;
    event.preventDefault(); // WebKit 기본 메뉴를 막는다(Reload가 편집 중 WebContent를 재시작한다)
    const hit = hitFromEvent(event);
    const snapshot = snapshotOf();
    // 접힌 선택을 되살리면 **WebKit이 진짜 선택으로 다시 칠한다** — 우리가 흉내 낼 필요가 없다(실측: 되살린
    // 화면과 원래 선택 화면의 픽셀 차이 0.000%).
    restoreSelection(doc, snapshot);
    targetWindow.parent.postMessage(
      {
        channel,
        type: contextMenuMessageType,
        x: hit.x,
        y: hit.y,
        target: hit.target,
        href: hit.href,
        has_selection: snapshot.text.length > 0 || hasVisibleSelection(doc),
      },
      "*",
    );
  });
  return snapshotOf;
}

/** 렌더 iframe이 보낸 우클릭 메시지인가(다른 메시지와 구분). 값 검증까지 여기서 한다. */
export function parseRendererContextMenu(
  data: unknown,
): (MenuHit & { hasSelection: boolean }) | null {
  if (typeof data !== "object" || data === null) return null;
  const record = data as Record<string, unknown>;
  if (record.type !== contextMenuMessageType) return null;
  if (typeof record.x !== "number" || typeof record.y !== "number") return null;
  if (!Number.isFinite(record.x) || !Number.isFinite(record.y)) return null;
  const target = record.target;
  if (target !== "text" && target !== "link" && target !== "image" && target !== "empty")
    return null;
  return {
    x: record.x,
    y: record.y,
    target,
    href: typeof record.href === "string" ? record.href : "",
    hasSelection: record.has_selection === true,
  };
}

export type MenuOpenParams = {
  editor_epoch: number;
  x: number;
  y: number;
  target: MenuTarget;
  has_selection: boolean;
  href: string;
};

/**
 * shell에서 쓴다. 자기 문서의 우클릭과 렌더 iframe이 넘긴 우클릭을 **한 경로로** 모아 브리지에 올린다.
 *
 * `getEditorEpoch`는 현재 문서 epoch를 준다(없으면 아직 문서가 안 열린 상태라 메뉴를 열지 않는다).
 * `frameRect`는 렌더 iframe의 위치를 준다 — iframe 좌표에 더해 shell 뷰포트 좌표로 만든다.
 */
export function installShellContextMenu(options: {
  doc: Document;
  targetWindow: Window;
  channel: string;
  getEditorEpoch: () => number | null;
  frameRect: () => { left: number; top: number } | null;
  /** 브리지 호출. 주입받는다 — 이 모듈이 shell 진입점(viewer)을 다시 import하면 순환이 된다. */
  openMenu: (request: MenuOpenParams) => void;
  /**
   * 편집 모드에서 **편집기 좌표로** 선택을 되살린다. 되살렸으면 true — 그러면 DOM Range 경로를 타지 않는다.
   * 읽기 모드처럼 편집기가 없으면 false를 돌려 DOM 경로로 떨어진다.
   */
  restoreEditorSelection: () => boolean;
  /** 렌더 iframe에 메시지를 보낸다(읽기 본문의 선택은 그 문서 안에 있다). */
  postToRenderer: (message: unknown) => void;
}): void {
  const {
    doc,
    targetWindow,
    channel,
    getEditorEpoch,
    frameRect,
    openMenu,
    restoreEditorSelection,
    postToRenderer,
  } = options;
  const snapshotOf = installSelectionCapture(doc);

  const open = (hit: MenuHit, hasSelection: boolean) => {
    const epoch = getEditorEpoch();
    if (epoch === null) return; // 문서가 아직 안 열렸으면 메뉴도 없다
    openMenu({
      editor_epoch: epoch,
      x: hit.x,
      y: hit.y,
      target: hit.target,
      has_selection: hasSelection,
      href: hit.href,
    });
  };

  doc.addEventListener("contextmenu", (event) => {
    if (!isMouseEvent(event)) return;
    event.preventDefault();
    const snapshot = snapshotOf();
    restoreSelection(doc, snapshot);
    open(hitFromEvent(event), snapshot.text.length > 0 || hasVisibleSelection(doc));
  });

  // native가 편집 명령(cut:/copy:/paste:)을 보내기 **직전에** 부른다. 문서 안에 편집 대상과 선택이 살아 있지
  // 않으면 WebKit은 명령을 받고도 아무것도 하지 않는다(실측: chain=true인데 무동작).
  targetWindow.addEventListener("maru:file-menu-focus", () => {
    postToRenderer({ channel, type: "menuFocus" }); // 읽기 본문은 iframe이 자기 선택을 되살린다
    // 편집 모드는 **편집기 자신의 좌표**로 되살린다 — DOM Range는 편집기가 DOM을 다시 만들면 그 노드가 문서에서
    // 빠져 `addRange`가 조용히 실패한다(실측: 7429자를 붙잡았는데 되살린 뒤 선택 0자).
    if (restoreEditorSelection()) return;
    const snapshot = snapshotOf();
    restoreSelection(doc, snapshot);
    const range = doc.getSelection()?.rangeCount === 1 ? doc.getSelection()?.getRangeAt(0) : null;
    const node = range?.commonAncestorContainer ?? null;
    const element = node === null ? null : isElement(node) ? node : node.parentElement;
    const editable =
      element?.closest<HTMLElement>("[contenteditable='true'], textarea, input") ?? null;
    editable?.focus({ preventScroll: true });
    restoreSelection(doc, snapshot);
  });

  targetWindow.addEventListener("message", (event) => {
    const data = event.data;
    if (typeof data !== "object" || data === null) return;
    if ((data as Record<string, unknown>).channel !== channel) return;
    const hit = parseRendererContextMenu(data);
    if (hit === null) return;
    const rect = frameRect();
    if (rect === null) return;
    open(
      { x: hit.x + rect.left, y: hit.y + rect.top, target: hit.target, href: hit.href },
      hit.hasSelection,
    );
  });
}
