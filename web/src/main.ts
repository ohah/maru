import { bootRenderer, bootShell } from "./viewer";

if (window.location.host === "app") bootShell(document, window);
else if (window.location.host === "render") bootRenderer(document, window);
