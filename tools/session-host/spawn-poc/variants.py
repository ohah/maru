"""Construct experimental variants from Maru's own source; never edit product files."""
from pathlib import Path

SOURCE = "src/platform/macos/session_host/bounded_process.zig"
HERE = Path(__file__).resolve().parent


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("source contract changed: " + old[:100])
    return text.replace(old, new)


def remove_parent_group_calls(text):
    marker = "    if (!establishProcessGroup(pid)) {"
    if text.count(marker) != 6:
        raise ValueError("expected six parent group checks")
    while marker in text:
        begin = text.index(marker)
        end = text.index("\n    }", begin) + len("\n    }")
        text = text[:begin] + text[end:]
    return text


def make_variant(text, name, templates=None):
    if name not in {"baseline", "parent-gate", "posix-spawn"}:
        raise ValueError("unknown variant")
    templates = templates or {name: (HERE / name).read_text() for name in ["parent_gate.zig.inc", "posix_spawn.zig.inc"]}
    if name == "baseline":
        return text
    text = remove_parent_group_calls(text)
    if name == "parent-gate":
        if text.count("const pid = c.fork();") != 3:
            raise ValueError("expected three fork sites")
        text = text.replace("const pid = c.fork();", "const pid = try pocForkGrouped();")
        if text.count("c.setpgid(0, 0) != 0 or") != 3:
            raise ValueError("expected three child group checks")
        text = text.replace("c.setpgid(0, 0) != 0 or", "")
        return text + "\n" + templates["parent_gate.zig.inc"]
    begin = text.index("    const max_fd = getdtablesize();", text.index("fn spawnChild("))
    end = text.index("\n}\n\nfn childExec(", begin)
    text = text[:begin] + """    return pocSpawnGrouped(executable, argv, environment, directory_fd, input_fd, .{
        input_fd orelse dev_null,
        pipe_fds[1],
        if (stderr_pipe_fds) |fds| fds[1] else if (capture_mode == .merged) pipe_fds[1] else dev_null,
        null,
    });""" + text[end:]
    for function, descriptors, child_function in [
        ("spawnEnvironmentInheritedSocket", "sockets", "childExecInheritedSocket"),
        ("spawnEnvironmentInheritedPipe", "receipt_pipe", "childExecInheritedPipe"),
    ]:
        begin = text.index("    const max_fd = getdtablesize();", text.index("pub fn " + function + "("))
        end_marker = f"    if (pid == 0) {child_function}(executable, argv, environment, {descriptors}, dev_null, max_fd);"
        end = text.index(end_marker, begin) + len(end_marker)
        replacement = f"    const pid = try pocSpawnGrouped(executable, argv, environment, null, null, .{{ dev_null, dev_null, dev_null, {descriptors}[1] }});"
        text = text[:begin] + replacement + text[end:]
    return text + "\n" + templates["posix_spawn.zig.inc"]
