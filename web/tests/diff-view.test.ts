import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { withEditorDom } from "./editor-dom";
import {
  bootDiff,
  createDiffScreen,
  loadDiff,
  parseDiffResult,
  rejectionText,
  retry_limit,
} from "../src/diff-view";

// 이 화면이 지켜야 하는 것은 "무엇을 보여 주는가"가 아니라 **무엇을 정상으로 착각하지 않는가**다.
// 빈 문서·모르는 응답을 정상 비교로 삼으면 사용자는 "변경 없음"으로 읽는다.

test("모르는 모양의 응답은 정상 결과로 삼지 않는다", () => {
  expect(parseDiffResult({ original: "a", modified: "b" }).kind).toBe("ready");
  expect(parseDiffResult({ pending: true }).kind).toBe("pending");
  expect(parseDiffResult({ rejected: "binary" })).toEqual({ kind: "rejected", reason: "binary" });
  // 한쪽만 있는 응답·null·문자열은 전부 거절이다.
  expect(parseDiffResult({ original: "a" }).kind).toBe("rejected");
  expect(parseDiffResult(null).kind).toBe("rejected");
  expect(parseDiffResult("ok").kind).toBe("rejected");
});

test("거절 이유는 사용자 문장으로 바뀌고 모르는 값은 노출하지 않는다", () => {
  expect(rejectionText("too_large")).toContain("너무 커서");
  expect(rejectionText("binary")).toContain("바이너리");
  // 내부 값을 그대로 화면에 싣지 않는다.
  expect(rejectionText("weird_internal_reason")).not.toContain("weird_internal_reason");
});

test("같은 내용이면 MergeView 대신 '변경 없음'을 말한다", () => {
  withEditorDom((dom) => {
    const host = dom.window.document.querySelector("main")!;
    const screen = createDiffScreen(host);
    screen.render({ kind: "ready", original: "same\n", modified: "same\n" });
    // 빈 MergeView를 그리면 사용자는 화면이 깨진 것으로 읽는다.
    expect(host.querySelector(".diff-merge")!.children.length).toBe(0);
    expect(host.querySelector(".diff-notice")!.textContent).toContain("변경이 없습니다");
    screen.destroy();
  });
});

test("shell의 iframe·상태 문구를 치운다(안 그러면 제품에서 화면 밖으로 밀린다)", () => {
  // 제품 index.html은 편집기 shell과 같은 문서라 100% 높이 iframe이 먼저 있다. body가 overflow:hidden이라
  // 그대로 두면 MergeView가 뷰포트 아래에 놓여 **아무것도 안 보인다**(리뷰에서 잡힌 결함).
  const dom = new JSDOM(
    `<!doctype html><body><p id="viewer-status">파일을 읽는 중</p>` +
      `<iframe id="renderer" src="maru-app://render/render.html"></iframe><main id="editor" hidden></main></body>`,
  );
  bootDiff(dom.window.document);
  const frame = dom.window.document.querySelector("#renderer")!;
  expect(frame.hasAttribute("hidden")).toBe(true);
  expect(frame.hasAttribute("src")).toBe(false);
  expect(dom.window.document.querySelector("#viewer-status")!.hasAttribute("hidden")).toBe(true);
  expect(dom.window.document.querySelector("#editor")!.hasAttribute("hidden")).toBe(false);
  dom.window.close();
});

test("pending이면 다시 묻고, 결과가 오면 멈춘다", async () => {
  await withEditorDom(async (dom) => {
    const host = dom.window.document.querySelector("main")!;
    const screen = createDiffScreen(host);
    const responses: unknown[] = [
      { pending: true },
      { pending: true },
      { original: "a\n", modified: "b\n" },
      { original: "never", modified: "reached" },
    ];
    let calls = 0;
    const payload = await loadDiff(
      dom.window.document,
      screen,
      async () => {}, // 테스트에서는 기다리지 않는다
      async () => responses[calls++]!,
    );
    expect(payload.kind).toBe("ready");
    expect(calls).toBe(3); // pending 두 번 → 결과 한 번에서 멈춘다(그 뒤 응답은 쓰지 않는다)
    expect(host.querySelector(".diff-merge")!.children.length).toBeGreaterThan(0);
    screen.destroy();
  });
});

test("계속 pending이면 무한 재시도하지 않고 그 사실을 화면에 말한다", async () => {
  await withEditorDom(async (dom) => {
    const host = dom.window.document.querySelector("main")!;
    const screen = createDiffScreen(host);
    let calls = 0;
    const payload = await loadDiff(
      dom.window.document,
      screen,
      async () => {},
      async () => {
        calls += 1;
        return { pending: true };
      },
    );
    expect(payload.kind).toBe("rejected");
    expect(calls).toBe(retry_limit + 1);
    expect(host.querySelector(".diff-notice")!.hasAttribute("hidden")).toBe(false);
    screen.destroy();
  });
});

test("브리지가 실패하면 이유를 지어내지 않는다", async () => {
  await withEditorDom(async (dom) => {
    const host = dom.window.document.querySelector("main")!;
    const screen = createDiffScreen(host);
    const payload = await loadDiff(
      dom.window.document,
      screen,
      async () => {},
      async () => {
        throw new Error("bridge denied");
      },
    );
    expect(payload.kind).toBe("rejected");
    // 내부 오류 문구가 화면에 새지 않는다.
    expect(host.querySelector(".diff-notice")!.textContent).not.toContain("bridge denied");
    screen.destroy();
  });
});
