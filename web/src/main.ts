import { renderMarkdown } from "./markdown";

const root = document.querySelector<HTMLElement>("#app");

if (root !== null) {
  root.innerHTML = renderMarkdown("# Maru file panel\n\nFP2 renderer ready.");
}
