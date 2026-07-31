import { expect, test } from "bun:test";
import { withEditorDom } from "./editor-dom";
import { fixture, mount } from "../src/diff-harness";

// jsdom은 layout이 없어(0×0) 표시 여부는 여기서 판정하지 못한다 — 그건 제품 WKWebView 게이트가 본다(§7.4).
// 여기서 고정하는 것은 **모델**이다: diff가 실제로 계산되는가, 마커가 DOM으로 나오는가, accept/reject가 문서를
// 어느 방향으로 바꾸는가. 이 셋이 깨지면 스모크가 초록이어도 의미가 없다.

test("두 형태 모두 fixture에서 chunk를 계산한다", () => {
  withEditorDom((dom) => {
    const parent = dom.window.document.querySelector("main")!;
    const harness = mount(parent);
    const probe = harness.probe();

    // 수정·삭제·추가가 fixture에 하나씩 들어 있다 — 0이면 마운트만 되고 비교가 안 된 것이다.
    expect(probe.split.chunk_count).toBeGreaterThan(0);
    expect(probe.unified.chunk_count).toBeGreaterThan(0);
    expect(probe.split.text.a).toBe(fixture.original);
    expect(probe.split.text.b).toBe(fixture.modified);
    harness.destroy();
  });
});

test("변경 강조와 gutter 마커가 DOM 요소로 나온다", () => {
  withEditorDom((dom) => {
    const parent = dom.window.document.querySelector("main")!;
    const harness = mount(parent);
    const probe = harness.probe();

    expect(probe.split.changed_elements).toBeGreaterThan(0);
    expect(probe.unified.changed_elements).toBeGreaterThan(0);
    expect(probe.unified.gutter_markers).toBeGreaterThan(0);
    harness.destroy();
  });
});

test("accept는 수정본을 확정하고 chunk를 하나 줄인다", () => {
  withEditorDom((dom) => {
    const parent = dom.window.document.querySelector("main")!;
    const harness = mount(parent);
    const before = harness.probe().unified.chunk_count;

    expect(harness.acceptFirstChunk()).toBe(true);
    const after = harness.probe();
    expect(after.unified.chunk_count).toBe(before - 1);
    // 받아들였으므로 문서는 수정본 그대로다(원본으로 되돌지 않는다).
    expect(after.unified.text.split("\n")[1]).toBe("BETA");
    harness.destroy();
  });
});

test("reject는 그 구간을 원본 내용으로 되돌린다", () => {
  withEditorDom((dom) => {
    const parent = dom.window.document.querySelector("main")!;
    const harness = mount(parent);

    expect(harness.rejectFirstChunk()).toBe(true);
    const after = harness.probe();
    // 첫 chunk는 `beta`→`BETA` 수정이었다 — 되돌리면 원본 문자열이 돌아온다.
    expect(after.unified.text.split("\n")[1]).toBe("beta");
    harness.destroy();
  });
});

test("스타일은 이 문서에만 있고 격리 렌더 문서를 만들지 않는다", () => {
  withEditorDom((dom) => {
    const parent = dom.window.document.querySelector("main")!;
    const harness = mount(parent);
    const probe = harness.probe();

    // CM6·merge의 style-mod가 문서 루트에 `<style>`을 넣는다 — 있어야 정상이고, 전부 이 문서 소유여야 한다(§7.2 불변식 1).
    expect(probe.style_elements).toBeGreaterThan(0);
    expect(probe.styles_all_in_this_document).toBe(true);
    // 하니스는 iframe을 만들지 않는다 — 스타일이 샐 대상 자체가 없어야 위 판정이 의미를 갖는다.
    expect(probe.iframe_count).toBe(0);
    harness.destroy();
  });
});
