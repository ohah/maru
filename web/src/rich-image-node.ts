/**
 * 리치 편집기의 이미지 — **문서에 적힌 경로는 그대로 두고 화면에만 실제 바이트를 채운다**(§2.5).
 *
 * 리치는 신뢰 shell에 살아서 `file:`을 직접 읽지 못한다. 그래서 마크다운 이미지가 그동안 리치에서 아예 보이지
 * 않았다 — `data-maru-asset-path`를 바이트로 바꾸는 코드가 읽기의 격리 renderer 안에만 있었기 때문이다.
 *
 * **노드 속성을 건드리면 안 된다.** `src`를 data URL로 갈아끼우면 그 URL이 직렬화돼 **파일에 저장된다** — 이미지
 * 한 장 때문에 문서가 수십 KB의 base64로 부풀고 원문 경로가 사라진다. 그래서 속성은 원문 경로로 두고 NodeView가
 * 그리는 DOM의 `src`만 채운다.
 *
 * 원격 URL은 채우지 않는다. 이는 결함이 아니라 정책이다 — 문서가 네트워크를 먼저 읽지 못하게 한다(§2.1).
 */

import Image, { type ImageOptions } from "@tiptap/extension-image";
import { normalizeAssetReference } from "./asset-path";
import type { ResolveAsset } from "./rich-raw-node";

/** 원래 이미지 옵션에 asset 해석기 하나를 더한다. 타입을 넓혀 두지 않으면 `configure`가 이 필드를 거부한다. */
type LocalImageOptions = ImageOptions & { resolveAsset: ResolveAsset | null };

export const LocalImage = Image.extend<LocalImageOptions>({
  addOptions() {
    // `parent`는 확장 대상의 기본 옵션이라 실제로는 항상 있지만 타입은 옵셔널이다. 캐스팅으로 좁히지 않으면
    // spread 결과가 부분 타입이 되어 확장 옵션에 할당되지 않는다.
    return { ...(this.parent?.() as ImageOptions), resolveAsset: null };
  },
  addNodeView() {
    const { resolveAsset } = this.options;
    return ({ node }: { node: { attrs: { src?: string; alt?: string; title?: string } } }) => {
      const dom = document.createElement("img");
      dom.className = "maru-rich-image";
      if (typeof node.attrs.alt === "string") dom.alt = node.attrs.alt;
      if (typeof node.attrs.title === "string") dom.title = node.attrs.title;

      // 읽기 파이프라인과 **같은 검증**을 쓴다 — 절대경로·상위 이동·scheme 있는 URL은 여기서 걸러진다.
      const normalized =
        typeof node.attrs.src === "string" ? normalizeAssetReference(node.attrs.src) : null;
      if (normalized !== null && resolveAsset !== null) {
        void resolveAsset(normalized).then((url) => {
          // 그 사이 조각이 다시 그려졌으면 이 노드는 문서 밖이다.
          if (url !== null && dom.isConnected) dom.src = url;
        });
      }
      return { dom };
    };
  },
});
