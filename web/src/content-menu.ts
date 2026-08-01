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
): void {
  doc.addEventListener("contextmenu", (event) => {
    if (!isMouseEvent(event)) return;
    event.preventDefault(); // WebKit 기본 메뉴를 막는다(Reload가 편집 중 WebContent를 재시작한다)
    const hit = hitFromEvent(event);
    targetWindow.parent.postMessage(
      {
        channel,
        type: contextMenuMessageType,
        x: hit.x,
        y: hit.y,
        target: hit.target,
        href: hit.href,
        has_selection: hasVisibleSelection(doc),
      },
      "*",
    );
  });
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

export type MenuAction = "copy" | "cut" | "paste" | "selectAll";

/** native가 되돌려 보낸 동작인가. 모르는 값은 무시한다(조용히 아무것도 하지 않는 편이 오동작보다 낫다). */
export function parseMenuAction(detail: unknown): { action: MenuAction; text: string } | null {
  if (typeof detail !== "object" || detail === null) return null;
  const record = detail as Record<string, unknown>;
  const action = record.action;
  if (action !== "copy" && action !== "cut" && action !== "paste" && action !== "selectAll")
    return null;
  return { action, text: typeof record.text === "string" ? record.text : "" };
}

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
  applyAction: (action: MenuAction, text: string) => void;
  /** 브리지 호출. 주입받는다 — 이 모듈이 shell 진입점(viewer)을 다시 import하면 순환이 된다. */
  openMenu: (request: MenuOpenParams) => void;
}): void {
  const { doc, targetWindow, channel, getEditorEpoch, frameRect, applyAction, openMenu } = options;

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
    open(hitFromEvent(event), hasVisibleSelection(doc));
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

  targetWindow.addEventListener("maru:file-menu-action", (event) => {
    const parsed = parseMenuAction((event as CustomEvent<unknown>).detail);
    if (parsed === null) return;
    applyAction(parsed.action, parsed.text);
  });
}
