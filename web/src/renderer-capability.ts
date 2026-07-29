/**
 * 읽기 프리뷰가 Mermaid 펜스를 native helper로 보낼 때 함께 싣는 6-field 신원(capability)이다.
 *
 * 왜 6개나 되는가: 이 값은 Web·Swift·Zig 세 계층이 각자 재검증하는 wire 계약이고, 늦게 도착한
 * helper 결과가 **다른** 문서·다른 펜스에 적용되는 것을 막는 것이 유일한 목적이다. 그래서 어느
 * 한 필드라도 현재 값과 다르면 결과를 버린다(부분 일치 허용 없음 — `capabilitiesEqual`).
 *
 * 읽기 프리뷰에는 편집 projection이 없으므로 `viewer.ts`가 펜스마다 `widgetId`만 증가시킨 값을
 * 만든다. 나머지 필드는 admission이 요구하는 non-zero 불변식을 채우는 값이고, 실제 신원 판정은
 * `editorEpoch`와 source hash가 한다.
 */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonNegativeSafeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}

function isPositiveSafeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}

export type RendererCapability = Readonly<{
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  widgetId: number;
  widgetGeneration: number;
  rendererInstance: number;
}>;

export function isRendererCapability(value: unknown): value is RendererCapability {
  return (
    isRecord(value) &&
    isPositiveSafeInteger(value.editorEpoch) &&
    isNonNegativeSafeInteger(value.documentRevision) &&
    isPositiveSafeInteger(value.projectionGeneration) &&
    isPositiveSafeInteger(value.widgetId) &&
    isPositiveSafeInteger(value.widgetGeneration) &&
    isPositiveSafeInteger(value.rendererInstance)
  );
}

export function capabilitiesEqual(left: RendererCapability, right: RendererCapability): boolean {
  return (
    left.editorEpoch === right.editorEpoch &&
    left.documentRevision === right.documentRevision &&
    left.projectionGeneration === right.projectionGeneration &&
    left.widgetId === right.widgetId &&
    left.widgetGeneration === right.widgetGeneration &&
    left.rendererInstance === right.rendererInstance
  );
}
