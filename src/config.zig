pub const action = @import("config/action.zig");
pub const appearance = @import("config/appearance.zig");
pub const keybinding = @import("config/keybinding.zig");
pub const theme = @import("config/theme.zig");
pub const loader = @import("config/loader.zig");
pub const serialize = @import("config/serialize.zig");
pub const schema = @import("config/schema.zig");

pub const Action = action.Action;
pub const GlobalAction = action.GlobalAction;
pub const GlobalBinding = keybinding.GlobalBinding;
pub const parseGlobalAction = action.parseGlobalAction;
pub const Config = theme.Config;
pub const Section = theme.Section;
pub const CursorConfig = theme.CursorConfig;
pub const CursorShape = theme.CursorShape;
pub const FontConfig = theme.FontConfig;
pub const ResolveError = appearance.ResolveError;
pub const ResolvedAppearance = appearance.ResolvedAppearance;
pub const ResolvedCursor = appearance.ResolvedCursor;
pub const ResolvedFontRequest = appearance.ResolvedFontRequest;
pub const ResolvedTheme = appearance.ResolvedTheme;
pub const ThemeConfig = theme.ThemeConfig;
pub const ShellConfig = theme.ShellConfig;
pub const AppBinding = keybinding.AppBinding;
pub const KeyBindingError = keybinding.KeyBindingError;
pub const KeyBindingResolver = keybinding.KeyBindingResolver;
pub const KeyChord = keybinding.KeyChord;
pub const ResolvedKey = keybinding.ResolvedKey;
pub const TerminalBinding = keybinding.TerminalBinding;
pub const TerminalInputMacro = keybinding.TerminalInputMacro;
pub const parseAction = action.parseAction;
pub const parseHexColor = appearance.parseHexColor;
pub const resolveAppearance = appearance.resolve;
pub const ParsedConfig = loader.Parsed;
pub const ConfigDiagnostic = loader.Diagnostic;
pub const SessionKeepAliveProvenance = loader.SessionKeepAliveProvenance;
pub const ConfigFileProvenance = loader.FileProvenance;
pub const parseConfig = loader.parse;
pub const loadConfigFile = loader.loadFile;
pub const loadConfigDefault = loader.loadDefault;
pub const defaultConfigPath = loader.defaultConfigPath;
pub const updateConfigText = loader.updateConfigText;
pub const ConfigKeyValue = loader.KeyValue;
pub const configKeyValues = serialize.configKeyValues;
pub const configValueForKey = serialize.valueForKey;
pub const updateConfigForKeys = serialize.updateForKeys;
pub const updateKeybindLines = loader.updateKeybindLines; // keybind recorder write-back(CS-4-3)
pub const KeybindRebind = loader.KeybindRebind;
pub const TerminalMacroWrite = loader.TerminalMacroWrite; // 터미널 매크로 write-back(chord 기준)
pub const updateTerminalMacroLines = loader.updateTerminalMacroLines; // keybind = chord = text:/esc:/ctrl: upsert
pub const removeTerminalMacroLines = loader.removeTerminalMacroLines; // 매크로 줄 chord 기준 삭제
pub const parseMacroRhs = loader.parseMacroRhs; // 매크로 rhs 파싱(GUI 커밋·검증)
pub const removeConfigLines = loader.removeConfigLines; // 키 줄 삭제(env 변수 삭제 등)
pub const removeKeybindLines = loader.removeKeybindLines; // keybind 줄 action 기준 삭제(unbind)
pub const appendKeybindUnbinds = loader.appendKeybindUnbinds; // keybind = chord = unbind 지시어(빌트인 죽이기)
pub const removeKeybindUnbindLines = loader.removeKeybindUnbindLines; // keybind = chord = unbind 줄 chord 기준 삭제(stale 정리 — 재바인딩)
pub const updateGlobalKeybindLines = loader.updateGlobalKeybindLines; // 전역 keybind write-back(global:<chord> = action, PR1)
pub const GlobalKeybindRebind = loader.GlobalKeybindRebind;
pub const removeGlobalKeybindLines = loader.removeGlobalKeybindLines; // 전역 keybind 줄 action 기준 삭제(unbind)

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in config/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
