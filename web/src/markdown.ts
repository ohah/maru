import type { Element, Root } from "hast";
import rehypeKatex from "rehype-katex";
import rehypePrism from "rehype-prism-plus";
import rehypeRaw from "rehype-raw";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkFrontmatter from "remark-frontmatter";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { visit } from "unist-util-visit";
import { normalizeAssetReference } from "./asset-path";
import { frontmatterEntries } from "./frontmatter";

const sourceStartProperty = "dataMaruSourceStart";
const sourceEndProperty = "dataMaruSourceEnd";
const assetPathProperty = "dataMaruAssetPath";
const assetIdProperty = "dataMaruAssetId";

type AssetRenderMode = "path" | "opaque";

// 위치 attribute는 renderer가 직접 붙인다. **문서가 쓴 값은 먼저 지운다** — 이 이름들은 sanitize
// allowlist에 있으므로(§2.1 renderer-owned attribute), 지우지 않으면 raw HTML이 승격된 뒤 위조한 값이
// 그대로 통과한다. 예전에는 raw HTML을 파서 경계에서 버려 이 경로가 아예 없었다.
function rehypeSourcePositions() {
  return (tree: Root) => {
    visit(tree, "element", (node: Element) => {
      delete node.properties[sourceStartProperty];
      delete node.properties[sourceEndProperty];
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
      // 위치 attribute와 같은 이유로 문서가 쓴 값을 먼저 지운다. 이쪽은 더 나쁘다 — viewer가 이 값을
      // `readAsset` 인자로 쓰므로, 위조가 통과하면 문서가 **읽을 파일을 고르게** 된다.
      delete node.properties[assetPathProperty];
      delete node.properties[assetIdProperty];
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
    // 그릴 수 없는 이미지는 **요소째** 지운다. `src`만 지우면 빈 `<img>`가 남아 문서에 없던 점 하나가
    // 보인다(실측 — 원격 이미지 자리에 1px 자국이 남았다). 로컬 이미지는 위에서 asset 경로를 받았으므로
    // 여기 걸리지 않고, 나중에 viewer가 그 경로로 바이트를 채운다.
    visit(tree, "element", (node: Element, index, parent) => {
      if (node.tagName !== "img") return;
      if (node.properties[assetPathProperty] !== undefined) return;
      if (node.properties[assetIdProperty] !== undefined) return;
      if (parent === undefined || index === undefined) return;
      (parent as { children: unknown[] }).children.splice(index, 1);
      return index;
    });
    file.data.maruAtomicAssetPaths = atomicPaths;
  };
}

// KaTeX/Prism은 sanitizer 뒤에 trusted markup을 만든다. 특히 KaTeX의 error
// fallback은 MathML-only에서도 inline color style을 붙이므로, 최종 경계에서
// 실행·네트워크 가능 속성을 다시 제거해야 Markdown 파생 markup의 inline style 금지 계약이 유지된다
// (CSP hash는 entry HTML의 고정 critical background bytes 하나에만 일치한다).
/** GFM 체크 목록이 만드는 `<li class="task-list-item">` 안의 입력만 진짜 체크박스다. */
function isTaskListItem(parent: unknown): boolean {
  const className = (parent as Element | undefined)?.properties?.className;
  return Array.isArray(className) && className.includes("task-list-item");
}

function rehypeHardenTrustedOutput() {
  return (tree: Root) => {
    // 문서가 쓴 `<input>`을 지운다. allowlist는 GFM 체크 목록 때문에 `input`을 남기면서 `disabled
    // type="checkbox"`로 강제하는데, 그 결과 `<form><input name="a"></form>` 같은 마크업이 **아무 뜻 없는
    // 빈 체크박스**로 화면에 남는다(실측 — 폼은 사라졌는데 체크박스만 떠 있었다). 진짜 체크 목록은
    // `task-list-item` 안에 있으므로 그것만 남긴다.
    visit(tree, "element", (node: Element, index, parent) => {
      if (node.tagName !== "input" || isTaskListItem(parent)) return;
      if (parent === undefined || index === undefined) return;
      (parent as { children: unknown[] }).children.splice(index, 1);
      return index;
    });
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

const frontmatterTableClass = "maru-frontmatter";

/** sanitize allowlist 항목은 `[속성, 허용값…]` **튜플**이다 — 배열로 두면 스키마 타입에 맞지 않는다. */
const frontmatterClassRule: [string, string] = ["className", frontmatterTableClass];

/**
 * frontmatter를 문서 맨 위의 **메타데이터 표**로 그린다(사용자 결정 2026-08-01).
 *
 * `remark-frontmatter`는 블록을 `yaml` 노드로 만들 뿐이고, `remark-rehype`에는 그 노드의 핸들러가 없어
 * 기본적으로 출력에서 **사라진다**. 사라지는 편이 렌더 결과에는 충실하지만, 읽기 모드에서 이 값들을 확인할
 * 길이 아예 없어진다 — frontmatter는 그 문서의 제목·태그·공개 여부를 담는다.
 *
 * 값은 **해석하지 않고 글자 그대로** 옮긴다(`frontmatterEntries`). 표는 읽기 전용 표시이므로 원문과 다른
 * 것이 보이면 그게 곧 거짓말이다.
 */
function frontmatterTable(value: string): Element | undefined {
  const entries = frontmatterEntries(value);
  // 최상위 키가 없으면(주석뿐이거나 빈 블록) 빈 표를 만들지 않는다 — 표시할 것이 없다.
  if (entries.length === 0) return undefined;

  return {
    type: "element",
    tagName: "table",
    properties: { className: [frontmatterTableClass] },
    children: [
      {
        type: "element",
        tagName: "tbody",
        properties: {},
        children: entries.map((entry) => ({
          type: "element" as const,
          tagName: "tr",
          properties: {},
          children: [
            {
              type: "element" as const,
              tagName: "th",
              properties: {},
              children: [{ type: "text" as const, value: entry.key }],
            },
            {
              type: "element" as const,
              tagName: "td",
              properties: {},
              children: [{ type: "text" as const, value: entry.value }],
            },
          ],
        })),
      },
    ],
  };
}

const schema = {
  ...defaultSchema,
  // 태그를 지울 때 **안쪽 내용까지** 버릴 것들. 기본값은 `script` 하나여서, `<style>`을 지우면 CSS 본문이
  // 문단 텍스트로 남아 화면에 `body{display:none}`이 그대로 보인다(실측). 실행되지 않으니 위험은 아니지만
  // 문서에 없던 글자가 생기는 건 렌더 오류다.
  strip: [...(defaultSchema.strip ?? []), "style"],
  attributes: {
    ...defaultSchema.attributes,
    "*": [
      ...(defaultSchema.attributes?.["*"] ?? []),
      sourceStartProperty,
      sourceEndProperty,
      assetPathProperty,
      assetIdProperty,
    ],
    // 메타데이터 표에만 이 클래스 하나를 허용한다. 값까지 못박아 두면 문서가 같은 이름을 위조해도
    // (raw HTML은 이미 폐기되지만) 다른 클래스는 통과하지 못한다.
    table: [...(defaultSchema.attributes?.table ?? []), frontmatterClassRule],
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
      // frontmatter는 **문서 내용이 아니라 메타데이터**다. 이게 없으면 파서가 `---`를 구분선으로, 그 아래 줄을
      // setext 제목으로 읽어 `<hr>` + `<h2>title: 문서</h2>`로 그려진다(실측 — frontmatter가 있는 문서마다 보였다).
      // 이 플러그인은 그 블록을 yaml 노드로 만들고, 아래 handler가 그걸 메타데이터 표로 바꾼다.
      .use(remarkFrontmatter, ["yaml", "toml"])
      .use(remarkGfm)
      .use(remarkMath)
      // 문서에 직접 쓴 HTML(`<details>`·`<kbd>`·`<br>`…)을 여기서 버리지 않고 아래 `rehypeRaw`에 넘긴다.
      // **이 옵션 자체는 아무것도 허용하지 않는다** — raw 문자열을 트리에 남길 뿐이고, 무엇이 살아남는지는
      // `rehypeSanitize`의 allowlist가 단독으로 정한다(§2.1). 폐기 경계를 파서에서 sanitizer로 **옮긴** 것이다.
      .use(remarkRehype, {
        allowDangerousHtml: true,
        handlers: {
          // `toml`은 표로 그리지 않는다 — `키 = 값` 문법이라 같은 규칙으로 못 읽고, 잘못 그리느니 안 그린다.
          yaml: (_state: unknown, node: { value?: string }) => frontmatterTable(node.value ?? ""),
        },
      })
      // raw 문자열을 실제 element 트리로 판독한다. 문자열인 채로 sanitizer에 보내면 검사할 노드가 없어
      // 그대로 출력에 박히므로, **파싱이 sanitize보다 반드시 먼저**여야 한다.
      .use(rehypeRaw)
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
