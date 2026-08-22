import { defineComponent, h, onBeforeUnmount, onMounted, ref, watch, type PropType } from "vue";
import { mountTerminal, type Terminal, type TerminalOptions, type Theme } from "@maru/core";

/**
 * `<MaruTerminal />`. SFC가 아니라 렌더 함수로 쓴다 — 이 저장소의 번들러(zntc)가 `.vue`를
 * 다루지 않는다. 기능은 SFC와 동일하다.
 */
export const MaruTerminal = defineComponent({
  name: "MaruTerminal",
  props: {
    options: { type: Object as PropType<TerminalOptions>, default: undefined },
    theme: { type: Object as PropType<Theme>, default: undefined },
    autoFit: { type: Boolean, default: true },
  },
  emits: ["data", "title", "bell", "resize", "ready"],
  setup(props, { emit, expose }) {
    const host = ref<HTMLElement | null>(null);
    let mounted: ReturnType<typeof mountTerminal> | null = null;

    onMounted(() => {
      if (!host.value) return;
      mounted = mountTerminal(host.value, {
        options: props.options,
        theme: props.theme,
        autoFit: props.autoFit,
        onData: (b) => emit("data", b),
        onTitle: (t) => emit("title", t),
        onBell: () => emit("bell"),
        onResize: (s) => emit("resize", s),
        onReady: (t) => emit("ready", t),
      });
    });

    watch(
      () => [props.theme, props.options],
      () => mounted?.update({ options: props.options, theme: props.theme, autoFit: props.autoFit }),
    );

    onBeforeUnmount(() => {
      mounted?.destroy();
      mounted = null;
    });

    expose({
      terminal: (): Terminal | null => mounted?.terminal ?? null,
    });

    return () => h("div", { ref: host });
  },
});

export default MaruTerminal;
export type { Terminal };
