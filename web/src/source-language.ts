// text kind(docs/file-panel.md §2.2) 소스 편집기의 CM6 언어·하이라이트. markdown 읽기 프리뷰 파이프라인과 무관한
// 순수 소스 표시라 여기서는 확장자별 문법과 theme 토큰 매핑만 정한다. 색은 theme 책임(§1)이라 HighlightStyle은
// CSS custom property(app.css/네이티브 주입)만 참조하고 hex를 직접 박지 않는다. 전용 lang 패키지가 없는 언어는
// @codemirror/legacy-modes의 StreamLanguage로 켠다(toml·shell·rust·go·c/c++ 등).

import { HighlightStyle, StreamLanguage, syntaxHighlighting } from "@codemirror/language";
import { css } from "@codemirror/lang-css";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { python } from "@codemirror/lang-python";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";
import { c, cpp, csharp, dart, java, kotlin, scala } from "@codemirror/legacy-modes/mode/clike";
import { clojure } from "@codemirror/legacy-modes/mode/clojure";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { go } from "@codemirror/legacy-modes/mode/go";
import { groovy } from "@codemirror/legacy-modes/mode/groovy";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { r } from "@codemirror/legacy-modes/mode/r";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { rust } from "@codemirror/legacy-modes/mode/rust";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { standardSQL } from "@codemirror/legacy-modes/mode/sql";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import type { Extension } from "@codemirror/state";
import { tags as t } from "@lezer/highlight";

// Lezer highlight 태그 → Maru theme 토큰(`--maru-syntax-*`). 값이 없는 태그는 CanvasText 기본색으로 떨어진다.
const maruHighlightStyle = HighlightStyle.define([
  {
    tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.operatorKeyword, t.definitionKeyword],
    color: "var(--maru-syntax-keyword)",
  },
  { tag: [t.string, t.special(t.string), t.regexp], color: "var(--maru-syntax-string)" },
  { tag: [t.attributeValue], color: "var(--maru-syntax-string)" },
  {
    tag: [t.number, t.integer, t.float, t.bool, t.null, t.atom],
    color: "var(--maru-syntax-number)",
  },
  {
    tag: [t.comment, t.lineComment, t.blockComment, t.docComment],
    color: "var(--maru-syntax-comment)",
    fontStyle: "italic",
  },
  {
    tag: [t.propertyName, t.definition(t.propertyName)],
    color: "var(--maru-syntax-property)",
  },
  { tag: [t.typeName, t.className, t.namespace], color: "var(--maru-syntax-type)" },
  {
    tag: [t.function(t.variableName), t.function(t.propertyName)],
    color: "var(--maru-syntax-function)",
  },
  {
    tag: [t.operator, t.punctuation, t.separator, t.bracket, t.brace, t.paren],
    color: "var(--maru-syntax-punctuation)",
  },
  { tag: [t.tagName, t.angleBracket], color: "var(--maru-syntax-tag)" },
  { tag: [t.attributeName], color: "var(--maru-syntax-attribute)" },
  { tag: [t.invalid], color: "var(--maru-syntax-invalid)" },
]);

// wire 값은 Zig `file_panel_bridge.TextLanguage.wireName`과 일대일. 알 수 없거나 `plain`이면 문법 없이 편집만
// 가능한 순수 텍스트 편집기다.
function languageForWire(wire: string | null): Extension | null {
  switch (wire) {
    case "json":
      return json();
    case "javascript":
      return javascript();
    case "typescript":
      return javascript({ typescript: true });
    case "python":
      return python();
    case "css":
      return css();
    case "xml":
      return xml();
    case "yaml":
      return yaml();
    case "toml":
      return StreamLanguage.define(toml);
    case "ini":
      return StreamLanguage.define(properties);
    case "shell":
      return StreamLanguage.define(shell);
    case "sql":
      return StreamLanguage.define(standardSQL);
    case "rust":
      return StreamLanguage.define(rust);
    case "go":
      return StreamLanguage.define(go);
    case "c":
      return StreamLanguage.define(c);
    case "cpp":
      return StreamLanguage.define(cpp);
    case "java":
      return StreamLanguage.define(java);
    case "csharp":
      return StreamLanguage.define(csharp);
    case "kotlin":
      return StreamLanguage.define(kotlin);
    case "swift":
      return StreamLanguage.define(swift);
    case "ruby":
      return StreamLanguage.define(ruby);
    case "lua":
      return StreamLanguage.define(lua);
    case "dockerfile":
      return StreamLanguage.define(dockerFile);
    case "perl":
      return StreamLanguage.define(perl);
    case "r":
      return StreamLanguage.define(r);
    case "powershell":
      return StreamLanguage.define(powerShell);
    case "groovy":
      return StreamLanguage.define(groovy);
    case "scala":
      return StreamLanguage.define(scala);
    case "haskell":
      return StreamLanguage.define(haskell);
    case "clojure":
      return StreamLanguage.define(clojure);
    case "dart":
      return StreamLanguage.define(dart);
    default:
      return null;
  }
}

export function sourceLanguageExtensions(wire: string | null): Extension[] {
  const extensions: Extension[] = [syntaxHighlighting(maruHighlightStyle)];
  const language = languageForWire(wire);
  if (language !== null) extensions.push(language);
  return extensions;
}
