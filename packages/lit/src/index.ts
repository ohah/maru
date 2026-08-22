import { LitElement, css, html, type PropertyValues } from "lit";
import { mountTerminal, type Terminal, type TerminalOptions, type Theme } from "@maru/core";

/**
 * `<maru-terminal>`. 데코레이터 대신 `static properties`를 쓴다 — 이 저장소의 번들러(zntc)에
 * `experimentalDecorators`를 켜지 않기 위해서다. 동작은 동일하다.
 *
 * ```html
 * <maru-terminal style="width:100%;height:400px"></maru-terminal>
 * ```
 */
export class MaruTerminalElement extends LitElement {
  static override styles = css`
    :host {
      display: block;
    }
    .host {
      width: 100%;
      height: 100%;
    }
  `;

  static override properties = {
    options: { type: Object },
    theme: { type: Object },
    autoFit: { type: Boolean, attribute: "auto-fit" },
  };

  declare options?: TerminalOptions;
  declare theme?: Theme;
  declare autoFit: boolean;

  #mounted: ReturnType<typeof mountTerminal> | null = null;

  constructor() {
    super();
    this.autoFit = true;
  }

  /** 코어 인스턴스. `ready` 이벤트 뒤에 유효하다. */
  get terminal(): Terminal | null {
    return this.#mounted?.terminal ?? null;
  }

  override firstUpdated(): void {
    const host = this.renderRoot.querySelector<HTMLElement>(".host");
    if (!host) return;
    this.#mounted = mountTerminal(host, {
      options: this.options,
      theme: this.theme,
      autoFit: this.autoFit,
      onData: (bytes) => this.dispatchEvent(new CustomEvent("data", { detail: bytes })),
      onTitle: (title) => this.dispatchEvent(new CustomEvent("title", { detail: title })),
      onBell: () => this.dispatchEvent(new CustomEvent("bell")),
      onResize: (size) => this.dispatchEvent(new CustomEvent("resize", { detail: size })),
      onReady: (term) => this.dispatchEvent(new CustomEvent("ready", { detail: term })),
    });
  }

  override updated(changed: PropertyValues): void {
    if (changed.has("theme") || changed.has("options")) {
      this.#mounted?.update({ options: this.options, theme: this.theme, autoFit: this.autoFit });
    }
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    this.#mounted?.destroy();
    this.#mounted = null;
  }

  override render() {
    return html`<div class="host"></div>`;
  }
}

if (!customElements.get("maru-terminal")) {
  customElements.define("maru-terminal", MaruTerminalElement);
}

declare global {
  interface HTMLElementTagNameMap {
    "maru-terminal": MaruTerminalElement;
  }
}

export type { Terminal };
