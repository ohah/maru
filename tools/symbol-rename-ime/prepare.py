"""Reuse private name-input instrumentation with symbol/LSP witnesses."""
import importlib.util


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def once(text,old,new):
    if text.count(old)!=1:raise RuntimeError('instrumentation anchor drift: '+old[:80])
    return text.replace(old,new,1)


def prepare(repo,snapshot):
    base=repo/'tools/untitled-save-ime'
    load('first_save_prepare',base/'prepare.py').prepare(repo,snapshot)
    fixture=snapshot/'src/platform/macos/app_session/debug_fixtures.zig'
    fixture.write_text(once(fixture.read_text(),(base/'probe.zig.inc').read_text(),(repo/'tools/symbol-rename-ime/probe.zig.inc').read_text()))
    host=snapshot/'src/platform/macos/MaruAppHost.swift';text=host.read_text()
    split=text.index('// Private-copy driver. All editing');prefix,driver=text[:split],text[split:]
    driver=driver.replace('maru.untitled-first-save-ime.v1','maru.symbol-rename-ime.v1')
    driver=driver.replace('addressDocument("','addressDocument("base')
    driver=once(driver,'paletteIMEWitness(27) == paletteIMEHash("")','paletteIMEWitness(27) == paletteIMEHash("base")')
    old='paletteIMEWitness(30)==1 && paletteIMEWitness(31)==paletteIMEHash("first save body\\n") && paletteIMEWitness(32)==1 && paletteIMEWitness(33)==0'
    new='paletteIMEWitness(30)==0 && paletteIMEWitness(31)==paletteIMEHash(symbolBody) && paletteIMEWitness(32)==0 && paletteIMEWitness(33)==0 && paletteIMEWitness(40)==0'
    driver=once(driver,old,new)
    driver=once(driver,'    private var firstSaveCase:', '''    private var symbolBody: String {
        let body="int base(void) { return 41; }\\nint baseline = 0;\\n"
        let prefix=ProcessInfo.processInfo.environment["MARU_SYMBOL_UNICODE"] == "1" ? "/* 한😀 */ " : ""
        return firstSaveCase == "server-error" ? "// RENAMEFAIL\\n"+prefix+body : prefix+body
    }
    private var firstSaveCase:''')
    driver=once(driver,'"surface_id":paletteIMEWitness(34),','"surface_id":paletteIMEWitness(34), "rename_sent":paletteIMEWitness(40), "rename_done":paletteIMEWitness(41), "rename_error":paletteIMEWitness(42), "refused_stale":paletteIMEWitness(43), "document_version":paletteIMEWitness(45), "undo_len":paletteIMEWitness(46),')
    a=driver.index('                case 30:');b=driver.index('                default:',a)
    driver=driver[:a]+(repo/'tools/symbol-rename-ime/finish.swift.inc').read_text()+driver[b:]
    driver=driver.replace('@_silgen_name("maru_untitled_model") private func maru_untitled_model() -> UInt64','@_silgen_name("maru_symbol_model") private func maru_symbol_model(_ stage: UInt32) -> UInt64\n@_silgen_name("maru_symbol_invalidate") private func maru_symbol_invalidate() -> UInt64\n@_silgen_name("maru_symbol_undo") private func maru_symbol_undo() -> UInt64')
    host.write_text(prefix+driver)
