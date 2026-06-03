# Terminal Strategy Notes

Date: 2026-06-03
Source context: discussion while inspecting `/Users/yoon/Documents/workspace/ghostty`

This document captures the working strategy from the Ghostty terminal design discussion.
It is not a verbatim transcript. It is the condensed decision log and technical plan.

## Product Position

Build a lightweight native shell, not an IDE terminal and not a Warp-style workflow product.

The product should be:

- Native and fast.
- Small by default.
- Focused on core terminal behavior.
- Tab-oriented, with cmux-level tab ergonomics.
- Easy to customize through config and actions.
- Extensible later through WASM plugins.
- macOS-first, while keeping the core portable for future WebGPU, Windows, and Linux work.

The product should not start as:

- A tmux replacement.
- A workspace/session IDE.
- A command-block terminal.
- An AI terminal.
- A cloud/account product.
- A plugin platform first.
- A cross-platform app from day one.

Short version:

```text
Ghostty = feature-rich, high-quality native terminal
Maru    = smaller native shell, simple tabs, easy customization
```

## Initial Target

Start with macOS only.

```text
macOS host: Swift/AppKit, thin layer
Core:       Zig
Renderer:   Metal
Parser:     libghostty-vt at first, behind our facade
Future web: WebGPU only
```

SwiftUI layout is not the goal. Swift/AppKit is only the macOS host and OS integration layer.

Swift/AppKit should handle:

- NSWindow / NSView.
- Key input.
- IME / marked text.
- Menu integration.
- Clipboard.
- Focus.
- Drag/drop where needed.
- Accessibility later.

Zig should own:

- Terminal/session model.
- Tab model.
- Action registry.
- Config parser and hot reload.
- Terminal core facade.
- Render snapshots.
- Metal renderer.
- Future backend boundaries.

## Architecture

Keep Ghostty-specific APIs behind a local facade.

```text
Swift/AppKit Host
  -> Zig App/Core
    -> TerminalCoreFacade
      -> libghostty-vt initially
    -> RenderSnapshot
    -> MetalRenderer
```

Do not let the app depend directly on Ghostty types.

Suggested facade shape:

```zig
pub const TerminalCore = struct {
    pub fn write(self: *TerminalCore, bytes: []const u8) void {}
    pub fn resize(self: *TerminalCore, cols: u16, rows: u16) void {}
    pub fn snapshot(self: *TerminalCore) RenderSnapshot {}
    pub fn encodeKey(self: *TerminalCore, key: KeyEvent) []const u8 {}
};
```

This keeps future options open:

```text
implementation v1: libghostty-vt
implementation v2: vendored/forked ghostty-vt
implementation v3: custom engine
```

## Backend Boundaries

Design the boundaries now, but implement only the macOS path first.

```text
TerminalCore
  - VT/parser integration
  - terminal state
  - scrollback
  - render snapshot
  - no AppKit
  - no Metal
  - no forkpty directly exposed to app code

PtyBackend
  - macOS: forkpty
  - Windows: ConPTY later
  - Web: WebSocket remote PTY later

WindowBackend
  - macOS: AppKit
  - Windows: Win32/WinUI later
  - Linux: GTK/Wayland/X11 later
  - Web: browser host later

RendererBackend
  - macOS: Metal
  - Web: WebGPU
  - Windows: WebGPU native or D3D12
  - Linux: Vulkan/WebGPU/OpenGL, later decision

FontBackend
  - macOS: CoreText/HarfBuzz
  - Windows: DirectWrite/HarfBuzz later
  - Web: browser font/canvas metrics later
```

## Why Zig

Use Zig for the core/hot path because:

- The author already has strong Zig experience from a high-performance bundler.
- Ghostty is Zig, so its architecture is directly readable and reusable as a reference.
- Zig is good for explicit allocator control, terminal buffers, glyph atlas state, and C/ObjC/Metal interop.
- Zig keeps the core portable to WASM/WebGPU later.

Do not make everything Zig-only. Pure Zig for all macOS host behavior would turn the project into an AppKit binding project.

Recommended split:

```text
Zig: terminal core, session/tab model, render data, Metal renderer
Swift/AppKit: macOS shell only
```

## Ghostty Reference Scope

Use Ghostty as a design reference, not as a product template to clone.

Strongly reference:

- VT/render-state boundary.
- Parser/stream/terminal-state pipeline.
- Dirty tracking.
- Row/cell render iterators.
- Glyph atlas model.
- Metal pipeline structure.
- CoreText/HarfBuzz/font shaping setup.
- macOS input/IME host boundary.
- Test strategy.

Avoid copying wholesale:

- Large config surface.
- Native macOS tabs behavior.
- Split/workspace complexity.
- GTK/Linux host for v1.
- WebGL path.
- Inspector.
- Advanced feature parity as an initial goal.

Important Ghostty local files inspected:

```text
build.zig
src/renderer.zig
src/renderer/Metal.zig
src/renderer/generic.zig
src/renderer/shaders/shaders.metal
src/renderer/metal/shaders.zig
src/font/Atlas.zig
src/font/face/coretext.zig
src/terminal/Parser.zig
src/terminal/stream.zig
src/terminal/stream_terminal.zig
src/simd/vt.zig
include/ghostty/vt/render.h
include/ghostty/vt/terminal.h
macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
macos/Sources/Ghostty/Ghostty.Input.swift
```

## Ghostty Technical Findings

Ghostty GPU/rendering:

- It does not use wgpu/mach-gpu/Electron/Skia for its native renderer.
- It has its own renderer abstraction.
- macOS/iOS backend: Metal.
- Linux/BSD backend: OpenGL.
- Web target has a WebGL placeholder, but current `src/renderer/WebGL.zig` is effectively a stub.
- Text rendering uses glyph atlas data and custom shaders.
- macOS font path uses CoreText plus HarfBuzz.

Ghostty parser/core:

- It does not use `libvterm`, `vaxis`, or `alacritty_terminal`.
- It has a custom Zig VT parser in `src/terminal/Parser.zig`.
- The parser follows the DEC ANSI parser state machine model from vt100.net.
- The pipeline includes SIMD/UTF-8 fast paths, parser state machine, stream actions, terminal state updates, and render state.

Ghostty Web/WASM:

- The Web/WASM target exists mainly for `libghostty-vt` as an embeddable WebAssembly core.
- It is not evidence of a complete browser Ghostty app.
- WebGL is not relevant to our macOS v1.
- For Maru, long-term web should be WebGPU-only.

## MVP Scope

Build the smallest useful native terminal:

- Single terminal.
- Local shell.
- Tabs.
- Keybindings.
- Theme/font config.
- Config hot reload.
- Copy/paste/selection.
- Search.
- SSH/vim/tmux/neovim sanity.

Leave out of v1:

- Split panes.
- Workspace/session restore.
- AI.
- Cloud/account.
- Command block UI.
- Plugin runtime.
- GUI settings app.
- Heavy inspector.

Tab scope:

```text
Cmd+T        new tab
Cmd+W        close tab
Cmd+1..9     select tab
Cmd+Shift+[  previous tab
Cmd+Shift+]  next tab
Reorder tabs
Tab title from shell title/cwd/process
Close confirmation when needed
```

Initial model can be simple:

```zig
const AppWindow = struct {
    tabs: []TerminalSession,
    active_tab: usize,
};
```

Each tab:

```zig
const TerminalSession = struct {
    pty: PtyHandle,
    core: TerminalCore,
    render_state: RenderSnapshot,
    title: []const u8,
    cwd: ?[]const u8,
    process_state: ProcessState,
};
```

## Customization Strategy

Do not start with plugins.

Start with:

```text
config + action registry + keybinding map + hot reload
```

Everything routes through actions:

```text
Keybinding -> Action
Menu       -> Action
Command palette -> Action
```

Example config shape:

```toml
font.family = "JetBrains Mono"
font.size = 14
theme = "custom-dark"

[keys]
cmd+t = "new_tab"
cmd+w = "close_tab"
cmd+1 = "select_tab:1"
cmd+shift+left = "previous_tab"

[theme]
background = "#101010"
foreground = "#e8e8e8"
cursor = "#ffffff"
selection = "#334455"
```

## WASM Plugin Strategy

WASM plugins are a good long-term differentiator, but not v1.

Benefits:

- Multi-language plugin compatibility.
- Sandboxable extension model.
- Local-only extensibility.
- No native dylib ABI instability.

Risks:

- WASM runtime size and complexity.
- API versioning burden.
- Permissions model.
- Debugging/logging/diagnostics.
- Plugins blocking hot paths if designed poorly.

Allowed plugin areas later:

- Tab title formatter.
- Statusline.
- Command palette provider.
- Theme generator.
- Notification rule.
- Output matcher.
- Hyperlink provider.
- Shell integration event handler.

Forbidden plugin areas:

- Per-byte VT hook.
- Per-cell render hook.
- Metal draw loop.
- Keyboard critical path.
- PTY blocking path.
- Glyph shaping hot path.

Plugin execution should be async/off-hot-path:

```text
terminal event -> queue -> plugin worker -> result/action -> main app applies safely
```

Phasing:

```text
v1: config/action/keybindings
v2: command palette + statusline customization
v3: WASM plugin runtime
```

## Ghostty Comparison

Ghostty strengths:

- Very fast and responsive.
- Strong terminal compatibility.
- Native platform integration.
- Mature macOS/Linux terminal behavior.
- Custom Zig VT parser and renderer.
- Good font rendering and glyph handling.

Commonly relevant Ghostty drawbacks/opportunities:

- Windows support is not the main shipped target yet.
- Linux GTK/OpenGL can carry platform overhead and environment issues.
- `TERM=xterm-ghostty` can cause remote terminfo friction.
- macOS native tabs can be awkward with tiling window managers.
- Feature surface is broader than a tiny native shell.
- App extension/plugin model is not the central product philosophy.

Maru differentiation:

- Smaller surface.
- Simple custom-drawn tabs.
- Tiling-WM-friendly tab behavior.
- Action/config-first customization.
- WASM plugin path later.
- WebGPU-only future web strategy.
- Strong defaults, fewer features.

The goal is not to beat Ghostty's engine directly.

```text
Wrong goal: Ghostty보다 빠른 VT parser / Metal renderer
Right goal: Ghostty보다 작아서 체감이 빠른 native shell
```

Win by doing less:

- Less UI.
- Less config surface.
- Less background work.
- Less platform scope in v1.
- Less feature ambition.

## Testing Strategy

Terminal projects can be heavily tested, but not entirely through pure TDD.

Pure TDD areas:

- VT parser facade behavior.
- Terminal state.
- Screen/scrollback.
- Resize/reflow.
- Selection.
- Key encoding.
- Mouse encoding.
- Tab model.
- Action system.
- Config parser.
- Render snapshot generation.

Integration test areas:

- `forkpty`.
- Shell command execution.
- Resize -> `TIOCSWINSZ`.
- `ssh localhost`.
- `vim`, `tmux`, `less`, `htop` smoke tests.

Snapshot/golden test areas:

- ANSI bytes -> final grid text/style.
- Asciinema cast -> screen state snapshots.
- Render snapshot -> glyph/background/cursor instances.

Hard to test with pure TDD:

- Metal pixel output.
- Font rasterization exact pixels.
- IME/marked text.
- AppKit focus/menu/clipboard/accessibility.
- GPU driver issues.

Recommended approach:

```text
Core: TDD
PTY/SSH: integration tests
Renderer data: snapshot/golden tests
Metal/AppKit/IME: smoke + screenshot + manual matrix
```

Ghostty local test scale observed:

```text
Zig test declarations: 3,106
Zig files with tests: 237
macOS Swift/XCTest-related files: 27
test/ directory files: about 4,019
fuzz corpus files: about 4,002
```

Distribution observed:

```text
src/terminal: 2,114 tests
src/input:      239 tests
src/config:     173 tests
src/font:       133 tests
src/cli:        100 tests
src/termio:      30 tests
src/renderer:    23 tests
```

This suggests Ghostty strongly tests terminal core behavior and fuzzes parser/stream/OSC paths, while renderer/GUI is tested more lightly and needs smoke/manual coverage.

## SSH Testing

Two cases:

1. Developing over SSH on a remote Mac:
   - Core tests and build commands are fine.
   - GUI/Metal/AppKit tests need an actual macOS GUI session, not just a bare SSH session.

2. Testing Maru's terminal behavior with SSH:
   - Must be part of integration testing.
   - Use `ssh localhost` or a controlled VM/container before relying on external servers.

SSH should test:

- Remote prompt.
- `vim`.
- `tmux`.
- `htop`.
- Resize propagation.
- Bracketed paste.
- Mouse reporting.
- Alternate screen.
- UTF-8 and Korean text.
- TERM/terminfo behavior.

## Estimated Timeline

Assumptions:

- macOS first.
- Zig core.
- Swift/AppKit thin host.
- `libghostty-vt` or Ghostty-derived design behind a facade.
- Direct Metal renderer.
- No plugins in v1.

Estimate:

```text
2 weeks:
  Empty macOS window, Zig bridge, PTY connection, bytes into terminal core.

4-6 weeks:
  Basic Metal rendering, ASCII/color/cursor, zsh/vim/htop basics.

8-10 weeks:
  Input, resize, selection, copy/paste, search, scrollback stabilization.

3-4 months:
  Tabs, config, actions, theme/font hot reload, daily-driver alpha.

6+ months:
  Distribution-level stability, polish, edge cases, broader compatibility.
```

If a custom parser is built from scratch, this schedule no longer applies.

## Key Decision

Build a smaller terminal, not a bigger Ghostty.

```text
Use Ghostty as the technical reference.
Hide Ghostty/libghostty-vt behind a facade.
Ship macOS first.
Keep the product minimal.
Make customization simple.
Reserve WASM plugins for later.
```
