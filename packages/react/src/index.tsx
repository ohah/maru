import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";
import { mountTerminal, type Terminal, type TerminalProps } from "@maru/core";

export interface MaruTerminalHandle {
  /** 코어 인스턴스. `open()` 이후에만 채워진다. */
  readonly terminal: Terminal | null;
}

export type MaruTerminalProps = TerminalProps & {
  className?: string;
  style?: React.CSSProperties;
};

/**
 * `<MaruTerminal />`. **마운트 이후에만** 터미널을 만든다 — 모듈 로드 시점에 DOM·Worker를
 * 건드리면 서버 렌더가 깨진다.
 */
export const MaruTerminal = forwardRef<MaruTerminalHandle, MaruTerminalProps>(function MaruTerminal(
  { className, style, ...props },
  ref,
) {
  const hostRef = useRef<HTMLDivElement>(null);
  const mountRef = useRef<ReturnType<typeof mountTerminal> | null>(null);
  const propsRef = useRef(props);
  propsRef.current = props;

  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    // props 는 ref 로 읽는다 — 콜백이 바뀔 때마다 터미널을 다시 만들면 화면이 초기화된다.
    const mounted = mountTerminal(el, propsRef.current);
    mountRef.current = mounted;
    return () => {
      mounted.destroy();
      mountRef.current = null;
    };
  }, []);

  useEffect(() => {
    mountRef.current?.update(propsRef.current);
  }, [props.theme, props.options]);

  useImperativeHandle(
    ref,
    () => ({
      get terminal() {
        return mountRef.current?.terminal ?? null;
      },
    }),
    [],
  );

  return <div ref={hostRef} className={className} style={style} />;
});

export type { Terminal, TerminalProps };
