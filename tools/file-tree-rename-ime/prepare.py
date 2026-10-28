"""Reuse first-save orchestration, replacing only the private file-tree witnesses."""
import importlib.util


def load(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def once(text, old, new):
    if text.count(old)!=1: raise RuntimeError('instrumentation anchor drift: '+old[:80])
    return text.replace(old,new,1)


def prepare(repo,snapshot):
    base=repo/'tools/untitled-save-ime'
    load('first_save_prepare',base/'prepare.py').prepare(repo,snapshot)
    fixture=snapshot/'src/platform/macos/app_session/debug_fixtures.zig'
    fixture.write_text(once(fixture.read_text(),(base/'probe.zig.inc').read_text(),
                            (repo/'tools/file-tree-rename-ime/probe.zig.inc').read_text()))
    host=snapshot/'src/platform/macos/MaruAppHost.swift'
    text=host.read_text()
    start=text.index('// Private-copy driver. All editing')
    before,driver=text[:start],text[start:]
    driver=driver.replace('maru.untitled-first-save-ime.v1','maru.file-tree-rename-ime.v1')
    driver=driver.replace('addressDocument("','addressDocument("base')
    driver=once(driver,'paletteIMEWitness(27) == paletteIMEHash("")','paletteIMEWitness(27) == paletteIMEHash("base")')
    start=driver.index('                case 30:');end=driver.index('                default:',start)
    driver=driver[:start]+(repo/'tools/file-tree-rename-ime/finish.swift.inc').read_text()+driver[end:]
    host.write_text(before+driver)
    instrument_selection(snapshot)


def instrument_selection(snapshot):
    path=snapshot/'src/platform/macos/app_session/file_panel.zig'
    text=path.read_text()
    needle='            if (self.file_tree_selection.generation == result.selection_generation)'
    if text.count(needle)!=2:raise RuntimeError('mutation selection anchor drift')
    text=text.replace(needle,'            std.debug.print("TREE_RESULT op={s} admitted={d} current={d} selected={s} target={s}\\n", .{@tagName(result.operation),result.selection_generation,self.file_tree_selection.generation,self.file_tree_selection.path() orelse "",result.target});\n'+needle)
    needle='    const resolved = self.file_tree_selection.reconcile(self.file_tree_rows.items) orelse return;'
    repl="""    const previous_generation = self.file_tree_selection.generation;
    var previous_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const previous_path = self.file_tree_selection.path() orelse "";
    @memcpy(previous_path_buf[0..previous_path.len], previous_path);
    const previous_len = previous_path.len;
    if (self.file_tree_selection.index(self.file_tree_rows.items) == null) {
        for (self.file_tree_rows.items) |row| switch (row) {
            .root => |r| std.debug.print("TREE_ROW root={s} expanded={any} loading={any}\\n", .{r.path,r.expanded,r.loading}),
            .directory => |r| std.debug.print("TREE_ROW dir={s} expanded={any} loading={any}\\n", .{r.path,r.expanded,r.loading}),
            .file => |r| std.debug.print("TREE_ROW file={s}\\n", .{r.path}),
            else => {},
        };
    }
    const resolved = self.file_tree_selection.reconcile(self.file_tree_rows.items) orelse return;
    if (previous_generation != self.file_tree_selection.generation)
        std.debug.print("TREE_RECONCILE before={d}:{s} after={d}:{s}\\n", .{previous_generation,previous_path_buf[0..previous_len],self.file_tree_selection.generation,self.file_tree_selection.path() orelse ""});"""
    path.write_text(once(text,needle,repl))
