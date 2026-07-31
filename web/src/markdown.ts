import type { Element, Root } from "hast";
import rehypeKatex from "rehype-katex";
import rehypePrism from "rehype-prism-plus";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { visit } from "unist-util-visit";
import { normalizeAssetReference } from "./asset-path";

const sourceStartProperty = "dataMaruSourceStart";
const sourceEndProperty = "dataMaruSourceEnd";
const assetPathProperty = "dataMaruAssetPath";
const assetIdProperty = "dataMaruAssetId";

type AssetRenderMode = "path" | "opaque";

// 위치 attribute는 raw HTML을 HAST로 승격하기 전에가 아니라, raw HTML을 버린 뒤
// renderer가 직접 붙인다. 그래서 문서가 같은 이름을 위조해도 sanitize allowlist에 닿지 않는다.
function rehypeSourcePositions() {
  return (tree: Root) => {
    visit(tree, "element", (node: Element) => {
      if (node.position?.start === undefined || node.position.end === undefined) return;

      node.properties[sourceStartProperty] = encodePoint(node.position.start);
      node.properties[sourceEndProperty] = encodePoint(node.position.end);
    });
  };
}

// FP4의 readAsset URL 재작성 전에는 문서가 어떤 네트워크/번들 asset도 선행 로드하지
// 못하게 resource 속성을 없앤다. href는 클릭 정책이 소비할 데이터라 별도다.
function rehypeBlockResourceLoads(mode: AssetRenderMode) {
  return (tree: Root, file: { data: Record<string, unknown> }) => {
    const atomicPaths: string[] = [];
    visit(tree, "element", (node: Element) => {
      // Markdown image의 원래 src를 네트워크 sink로 남기지 않고, 검증된 상대 경로만 renderer-owned data attribute로
      // 옮긴다. FP4 viewer가 readAsset 결과를 data URL로 바꿀 때 이 값만 소비한다.
      if (node.tagName === "img" && typeof node.properties.src === "string") {
        const normalized = normalizeAssetReference(node.properties.src);
        if (normalized !== null) {
          if (mode === "path") node.properties[assetPathProperty] = normalized;
          else {
            atomicPaths.push(normalized);
            node.properties[assetIdProperty] = String(atomicPaths.length);
          }
        }
      }
      delete node.properties.src;
      delete node.properties.srcSet;
      delete node.properties.poster;
    });
    file.data.maruAtomicAssetPaths = atomicPaths;
  };
}

// KaTeX/Prism은 sanitizer 뒤에 trusted markup을 만든다. 특히 KaTeX의 error
// fallback은 MathML-only에서도 inline color style을 붙이므로, 최종 경계에서
// 실행·네트워크 가능 속성을 다시 제거해야 Markdown 파생 markup의 inline style 금지 계약이 유지된다
// (CSP hash는 entry HTML의 고정 critical background bytes 하나에만 일치한다).
function rehypeHardenTrustedOutput() {
  return (tree: Root) => {
    visit(tree, "element", (node: Element) => {
      delete node.properties.style;
      delete node.properties.src;
      delete node.properties.srcSet;
      delete node.properties.poster;

      for (const property of Object.keys(node.properties)) {
        if (property.toLowerCase().startsWith("on")) delete node.properties[property];
      }
    });
  };
}

function encodePoint(point: { line: number; column: number; offset?: number }): string {
  return `${point.line}:${point.column}:${point.offset ?? -1}`;
}

const schema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    "*": [
      ...(defaultSchema.attributes?.["*"] ?? []),
      sourceStartProperty,
      sourceEndProperty,
      assetPathProperty,
      assetIdProperty,
    ],
  },
  protocols: {
    ...defaultSchema.protocols,
    // 링크의 http(s)는 FP5가 외부 브라우저로 라우팅하므로 href에 남긴다.
    // 반면 src는 scheme을 하나도 허용하지 않아 Markdown 이미지가 네트워크를 먼저
    // 읽지 못하게 한다. 상대 경로는 FP4 readAsset 경로가 생길 때 별도 URL로 바꾼다.
    src: [],
  },
};

function createProcessor(mode: AssetRenderMode) {
  return (
    unified()
      .use(remarkParse)
      .use(remarkGfm)
      .use(remarkMath)
      // allowDangerousHtml을 켜지 않는다. Markdown raw HTML node는 이 경계에서 폐기된다.
      .use(remarkRehype)
      .use(rehypeSourcePositions)
      .use(rehypeBlockResourceLoads, mode)
      .use(rehypeSanitize, schema)
      // sanitizer 뒤에는 사용자 AST가 아니라 핀된 renderer만 마크업을 만든다.
      // MathML-only는 KaTeX HTML의 inline style을 피해서 Markdown 파생 markup의 inline style 금지를 지킨다.
      // `throwOnError`는 넘기지 않는다 — 플러그인이 자기가 `true`로 덮어쓰고 실패 시 `false`로 재시도한다
      // (rehype-katex 소스 확인). 타입에서도 빠져 있는 옵션이라 우리 값은 여태 무시돼 왔다.
      .use(rehypeKatex, { output: "mathml", strict: "error" })
      .use(rehypePrism, { ignoreMissing: true })
      .use(rehypeHardenTrustedOutput)
      .use(rehypeStringify)
  );
}

const processor = createProcessor("path");
const atomicProcessor = createProcessor("opaque");

export function renderMarkdown(markdown: string): string {
  return String(processor.processSync(markdown));
}

export function renderAtomicMarkdown(
  markdown: string,
): Readonly<{ html: string; assetPaths: readonly string[] }> {
  const result = atomicProcessor.processSync(markdown);
  const assetPaths = result.data.maruAtomicAssetPaths;
  return {
    html: String(result),
    assetPaths: Array.isArray(assetPaths)
      ? assetPaths.filter((value): value is string => typeof value === "string")
      : [],
  };
}
