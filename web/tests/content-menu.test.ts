/**
 * 문서 영역 우클릭 메뉴에서 **web이 맡은 부분**만 검증한다(docs/file-panel.md §2.6) — 대상 판정, 렌더 iframe이
 * 넘긴 값 검증, native가 되돌려 준 동작 파싱이다. 메뉴 자체는 native가 그리므로 여기에 UI 테스트가 없다.
 *
 * 왜 터미널에서 중요한가: 이 값들은 **적대적일 수 있는 문서**가 정한다. 링크 주소·이미지 경로·좌표가 그대로
 * native 메뉴와 링크 열기로 흘러가므로, 경계에서 접지 못하면 문서가 앱 동작을 고르는 셈이 된다.
 */

import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  hasVisibleSelection,
  hitFromEvent,
  parseMenuAction,
  parseRendererContextMenu,
} from "../src/content-menu";

const dom = (body: string) => new JSDOM(`<!doctype html><body>${body}</body>`);

// 이벤트는 JSDOM realm에서 만든다 — 제품에서도 문서가 만든 이벤트가 들어오므로, bun realm의 생성자를 쓰면
// 실제와 다른 조건을 검사하게 된다(대상 판정이 realm-safe한지가 이 테스트의 요점 중 하나다).
const contextEvent = (dom: JSDOM, target: Element) => {
  const event = new dom.window.MouseEvent("contextmenu", {
    clientX: 40,
    clientY: 12,
    bubbles: true,
  });
  Object.defineProperty(event, "target", { value: target });
  return event as unknown as MouseEvent;
};

describe("우클릭 대상 판정", () => {
  test("링크 안의 이미지는 이미지로 잡는다(가장 안쪽이 이긴다)", () => {
    const jsdom = dom(
      `<a href="./doc.md"><img data-maru-asset-path="images/a.png" src="data:,"></a>`,
    );
    const image = jsdom.window.document.querySelector("img") as Element;
    const hit = hitFromEvent(contextEvent(jsdom, image));
    expect(hit.target).toBe("image");
    // 렌더 origin에서 src는 data: URL로 바뀌어 있으므로 **원본 경로**를 쓴다.
    expect(hit.href).toBe("images/a.png");
  });

  test("원본 경로가 없는 이미지는 추측한 값을 native에 넘기지 않는다", () => {
    const jsdom = dom(`<img src="data:image/png,x">`);
    const image = jsdom.window.document.querySelector("img") as Element;
    expect(hitFromEvent(contextEvent(jsdom, image)).href).toBe("");
  });

  test("링크·본문·여백을 구분한다", () => {
    const jsdom = dom(
      `<a href="https://example.test/a"><span id="s">글</span></a><p id="p">본문</p>`,
    );
    const doc = jsdom.window.document;
    const inLink = hitFromEvent(contextEvent(jsdom, doc.querySelector("#s") as Element));
    expect(inLink.target).toBe("link");
    expect(inLink.href).toBe("https://example.test/a");
    expect(hitFromEvent(contextEvent(jsdom, doc.querySelector("#p") as Element)).target).toBe(
      "text",
    );
  });
});

describe("선택 판정", () => {
  test("접힌 선택(캐럿)은 선택이 아니다", () => {
    const doc = dom(`<p id="p">본문</p>`).window.document;
    const range = doc.createRange();
    const node = doc.querySelector("#p")?.firstChild as Node;
    range.setStart(node, 1);
    range.setEnd(node, 1); // 캐럿 — 복사·잘라내기 대상이 아니다
    doc.getSelection()?.addRange(range);
    expect(hasVisibleSelection(doc)).toBe(false);

    const wide = doc.createRange();
    wide.setStart(node, 0);
    wide.setEnd(node, 2);
    doc.getSelection()?.removeAllRanges();
    doc.getSelection()?.addRange(wide);
    expect(hasVisibleSelection(doc)).toBe(true);
  });
});

describe("렌더 iframe이 넘긴 값", () => {
  const base = {
    type: "contextmenu",
    x: 10,
    y: 20,
    target: "link",
    href: "./a.md",
    has_selection: true,
  };

  test("정상 메시지는 좌표·대상·선택을 그대로 전한다", () => {
    const parsed = parseRendererContextMenu(base);
    expect(parsed).toEqual({ x: 10, y: 20, target: "link", href: "./a.md", hasSelection: true });
  });

  test("유한하지 않은 좌표·모르는 대상·다른 타입은 버린다", () => {
    // 좌표가 NaN/Inf면 native의 창 좌표 변환이 정의되지 않는다 — 경계에서 접는다.
    expect(parseRendererContextMenu({ ...base, x: Number.NaN })).toBeNull();
    expect(parseRendererContextMenu({ ...base, y: Number.POSITIVE_INFINITY })).toBeNull();
    expect(parseRendererContextMenu({ ...base, target: "<script>" })).toBeNull();
    expect(parseRendererContextMenu({ ...base, type: "setZoom" })).toBeNull();
    expect(parseRendererContextMenu(null)).toBeNull();
    // href가 문자열이 아니면 **거절이 아니라 빈 값**이다 — 메뉴는 열리되 링크 항목이 쓸 값이 없다.
    expect(parseRendererContextMenu({ ...base, href: 7 })?.href).toBe("");
  });
});

describe("native가 되돌려 준 동작", () => {
  test("닫힌 집합만 받고 붙여넣기 텍스트를 함께 전한다", () => {
    expect(parseMenuAction({ action: "copy" })).toEqual({ action: "copy", text: "" });
    expect(parseMenuAction({ action: "paste", text: "붙" })).toEqual({
      action: "paste",
      text: "붙",
    });
    for (const bad of [{ action: "eval" }, { action: 1 }, {}, null, "copy"]) {
      expect(parseMenuAction(bad)).toBeNull();
    }
  });
});
