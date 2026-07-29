/**
 * 읽기 프리뷰가 Mermaid 렌더를 native helper에 요청할 때 싣는 6-field capability를 검증한다.
 *
 * 왜 터미널에서 중요한가: 이 값은 늦게 도착한 helper 결과가 **다른 문서·다른 펜스**에 적용되는 것을
 * 막는 유일한 장치다. 문서를 닫았다 다시 열거나 편집으로 revision이 오른 뒤 이전 요청의 SVG가
 * 도착해도, 필드 하나라도 다르면 결과를 버려야 사용자가 엉뚱한 다이어그램을 보지 않는다.
 * 그래서 부분 일치는 통과하면 안 되고(모든 필드 비교), 0·음수·비정수는 애초에 capability가 아니다.
 */

import { describe, expect, test } from "bun:test";
import {
  capabilitiesEqual,
  isRendererCapability,
  type RendererCapability,
} from "../src/renderer-capability";

const capability: RendererCapability = {
  editorEpoch: 2,
  documentRevision: 3,
  projectionGeneration: 7,
  widgetId: 11,
  widgetGeneration: 13,
  rendererInstance: 17,
};

describe("renderer capability", () => {
  test("accepts a complete identity and rejects every missing field", () => {
    expect(isRendererCapability(capability)).toBe(true);
    for (const key of Object.keys(capability) as (keyof RendererCapability)[]) {
      const partial: Record<string, unknown> = { ...capability };
      delete partial[key];
      expect(isRendererCapability(partial)).toBe(false);
    }
  });

  test("rejects zero, negative, and non-integer identity fields", () => {
    // documentRevision만 0을 허용한다 — 아직 한 번도 편집하지 않은 문서의 정상 상태다.
    expect(isRendererCapability({ ...capability, documentRevision: 0 })).toBe(true);
    for (const key of Object.keys(capability) as (keyof RendererCapability)[]) {
      expect(
        isRendererCapability({ ...capability, [key]: key === "documentRevision" ? -1 : 0 }),
      ).toBe(false);
    }
    expect(isRendererCapability({ ...capability, widgetGeneration: 1.5 })).toBe(false);
    expect(isRendererCapability(null)).toBe(false);
    expect(isRendererCapability([capability])).toBe(false);
    expect(isRendererCapability("capability")).toBe(false);
  });

  test("equality requires every field so one stale value discards the result", () => {
    expect(capabilitiesEqual(capability, { ...capability })).toBe(true);
    for (const key of Object.keys(capability) as (keyof RendererCapability)[]) {
      expect(capabilitiesEqual(capability, { ...capability, [key]: capability[key] + 1 })).toBe(
        false,
      );
    }
  });
});
