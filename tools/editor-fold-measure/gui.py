#!/usr/bin/env python3
"""실제 격리 AppKit 앱에서 일정 간격 입력의 큐 지연·렌더 반환·접힘 갱신 시간을 잰다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def once(text,old,new):
    if text.count(old)!=1: raise RuntimeError(f"Nonunique GUI injection anchor: {old[:70]!r}")
    return text.replace(old,new)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("measurement",type=Path)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--web-deps",type=Path,required=True)
    parser.add_argument("--repetitions",type=int,default=3)
    parser.add_argument("--reuse",type=Path)
    parser.add_argument("--build-only",action="store_true")
    parser.add_argument("--product",action="store_true",help="Observe production sources without prototype clocks")
    parser.add_argument("--foreground",action="store_true")
    parser.add_argument("--fixture",type=Path)
    parser.add_argument("--intervals",default="50,250")
    parser.add_argument("--modes")
    args=parser.parse_args()
    selected_modes=list(map(int,(args.modes or ("0,1" if args.product else "0,1,2")).split(",")))
    if args.product and any(mode not in (0,1) for mode in selected_modes): parser.error("Product comparison supports modes 0 and 1 only")
    measurement=args.measurement.resolve()
    output=args.output.resolve()
    repo=Path(__file__).resolve().parents[2]
    if output==repo or repo in output.parents or (output.exists() and any(output.iterdir())):
        parser.error("GUI output must be a new directory outside the repository")
    output.mkdir(parents=True,exist_ok=True)
    templates=Path(__file__).resolve().parent
    if args.reuse:
        previous=json.loads(args.reuse.read_text())
        apps={int(mode):Path(data["path"]) for mode,data in previous["binaries"].items()}
        for mode, app in apps.items():
            if hashlib.sha256(app.read_bytes()).hexdigest() != previous["binaries"][str(mode)]["sha256"]:
                raise RuntimeError("Recorded GUI binary changed")
    else:
        apps={}
        for mode in selected_modes:
            origin=measurement/f"source-{mode}"
            source=output/f"source-{mode}"
            subprocess.run(["rsync","-a","--exclude=.zig-cache","--exclude=zig-out","--exclude=node_modules","--exclude=zig-pkg","--exclude=references",str(origin)+"/",str(source)+"/"],check=True)
            (source/"zig-pkg").symlink_to((origin/"zig-pkg").resolve(),target_is_directory=True)
            (source/"web/node_modules").symlink_to(args.web_deps.resolve(),target_is_directory=True)
            if not args.product:
                p=source/"src/syntax/tree_sitter.zig"
                text=p.read_text()
                text=once(text,"    pub var clock_ns: i64 = 0;","    pub var wall_clock: ?*const fn () i64 = null;\n    pub var clock_ns: i64 = 0;")
                text=once(text,"        self.deadline = clock_ns + delay_ns;","        if (wall_clock) |get| clock_ns = get();\n        self.deadline = clock_ns + delay_ns;")
                p.write_text(text)
            p=source/"src/platform/macos/app_session.zig"
            p.write_text(once(p.read_text(),"        debug_fixtures.maybeDebugOpenNativeEditor(self);","        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.ew2Observe(self);"))
            p=source/"src/platform/macos/app_session/debug_fixtures.zig"
            observer=(templates/"gui.zig.inc").read_text()
            if args.product:
                observer="\n".join(line for line in observer.splitlines() if "FoldProbe.wall_clock" not in line and "FoldProbe.clock_ns" not in line)+"\n"
                begin=observer.index("export fn maru_ew2_due_ns()")
                end=observer.index("export fn maru_ew2_inserted_bytes()",begin)
                observer=observer[:begin]+f"export fn maru_ew2_due_ns() callconv(.c) i64 {{ return 16_666_667; }}\nexport fn maru_ew2_mode() callconv(.c) u32 {{ return {mode}; }}\n\n"+observer[end:]
                observer=observer.replace("p.foldSpansFull(self.allocator,&expected)","p.foldSpans(self.allocator,&expected)")
            p.write_text(p.read_text()+"\n"+observer)
            p=source/"src/platform/macos/MaruAppHost.swift"
            p.write_text(once(p.read_text(),"        maybeRunEditorIMESmoke()\n","        maybeRunEditorIMESmoke()\n        maybeRunEW2GUI()\n")+"\n"+(templates/"gui.swift.inc").read_text())
            p=source/"src/platform/macos/maru_metal_renderer.m"
            p.write_text(once(p.read_text(),"    static const char *const gates[] = {",'    static const char *const gates[] = {\n        "MARU_EW2_GUI",'))
            print("GUI build",mode,flush=True)
            with (output/f"build-{mode}.log").open("wb") as log:
                subprocess.run(["mise","exec","--","zig","build","macos-app-bundle","-Doptimize=ReleaseFast","-j2"],cwd=source,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=1800)
            app=source/"zig-out/Maru.app/Contents/MacOS/maru-macos-app"
            if not app.exists():
                matches=list((source/"zig-out").glob("**/Maru.app/Contents/MacOS/maru-macos-app"))
                if len(matches)!=1: raise RuntimeError("Expected one GUI bundle")
                app=matches[0]
            apps[mode]=app
    app_manifest={"binaries":{mode:dict(path=str(app),sha256=hashlib.sha256(app.read_bytes()).hexdigest()) for mode,app in apps.items()}}
    (output/"apps.json").write_text(json.dumps(app_manifest,indent=2)+"\n")
    if args.build_only:
        print(output/"apps.json",flush=True)
        return
    # 빌드 뒤 모든 비교 입력은 같은 원문을 사용한다.
    source_file=(args.fixture or measurement/"fixtures/real-host.swift").resolve()
    input_bytes=source_file.read_bytes()
    rows=[]
    for rep in range(args.repetitions):
        modes=selected_modes if rep%2==0 else list(reversed(selected_modes))
        for mode in modes:
            for interval in map(int,args.intervals.split(",")):
                root=output/f"run-{rep}-{mode}-{interval}"
                root.mkdir()
                (root/"home").mkdir()
                (root/"artifacts").mkdir()
                (root/"config").write_text("session.keep-alive-after-quit = false\nlsp.enabled = false\n")
                document=root/source_file.name
                document.write_bytes(input_bytes)
                env={k:v for k,v in os.environ.items() if not k.startswith("MARU_")}
                env.update(HOME=str(root/"home"),CFFIXED_USER_HOME=str(root/"home"),XDG_CONFIG_HOME=str(root/"home/.config"),
                    XDG_CACHE_HOME=str(root/"cache"),XDG_STATE_HOME=str(root/"state"),MARU_CONFIG=str(root/"config"),
                    MARU_SESSION_HOST_ROOT=str(root/"host"),MARU_EDITOR_BACKUP_ROOT=str(root/"backups"),
                    MARU_EDITOR_RECOVERY_CHECKPOINT_TEST="maru-test-only-v1",MARU_MACOS_APP_SMOKE_MS="90000",
                    MARU_NATIVE_EDITOR=str(document),MARU_FT_WINDOW_SIZE="960x600",MARU_EW2_GUI="1",
                    MARU_EW2_GUI_FOREGROUND="1" if args.foreground else "0",MARU_EW2_GUI_OUTPUT=str(root/"artifacts"),MARU_EW2_GUI_INTERVAL_MS=str(interval))
                if args.foreground and '"CGSSessionScreenIsLocked"=Yes' in subprocess.check_output(["ioreg","-n","Root","-d1"],text=True):
                    raise RuntimeError("Unlock macOS before foreground measurement")
                if hashlib.sha256(apps[mode].read_bytes()).hexdigest() != app_manifest["binaries"][mode]["sha256"]:
                    raise RuntimeError("GUI binary changed before the run")
                print("GUI run",rep,mode,interval,flush=True)
                with (root/"app.log").open("wb") as log:
                    child=subprocess.Popen([str(apps[mode])],cwd=repo,env=env,stdout=log,stderr=log,start_new_session=True)
                    try: code=child.wait(timeout=100)
                    except subprocess.TimeoutExpired:
                        child.kill();child.wait();raise
                if hashlib.sha256(apps[mode].read_bytes()).hexdigest() != app_manifest["binaries"][mode]["sha256"]:
                    raise RuntimeError("GUI binary changed during the run")
                if code or "EW2_GUI_FINISH" not in (root/"app.log").read_text(): raise RuntimeError(f"GUI run failed: {root}")
                if document.read_bytes()!=input_bytes: raise RuntimeError("GUI fixture was saved unexpectedly")
                if args.foreground and '"CGSSessionScreenIsLocked"=Yes' in subprocess.check_output(["ioreg","-n","Root","-d1"],text=True):
                    raise RuntimeError("macOS locked during foreground measurement; preserve the run")
                report=json.loads((root/"artifacts/events.json").read_text())
                if report["mode"]!=mode or len(report["events"])!=20 or not report["valid"] or report["inserted_bytes"]!=20: raise RuntimeError("Wrong GUI mode or incomplete key sequence")
                if any(event.get("inserted_bytes") != index+1 for index,event in enumerate(report["events"])):
                    raise RuntimeError("Unexpected edit during the key sequence; preserve the run")
                if args.foreground and any(event["foreground"]!=1 for event in report["events"]): raise RuntimeError("A foreground sample lost focus; preserve the run and retry after unlock")
                for name in ("before","after"):
                    ppm=root/"artifacts"/(name+".ppm")
                    if not ppm.exists() or ppm.stat().st_size<1000: raise RuntimeError("Missing Metal capture")
                    subprocess.run(["sips","-s","format","png",str(ppm),"--out",str(ppm.with_suffix(".png"))],stdout=subprocess.DEVNULL,check=True)
                rows.append(dict(repetition=rep,interval_ms=interval,mode=mode,report=report,root=str(root)))
    manifest=dict(fixture=source_file.name,input_sha256=hashlib.sha256(input_bytes).hexdigest(),
        binaries={mode:dict(path=str(app),sha256=hashlib.sha256(app.read_bytes()).hexdigest()) for mode,app in apps.items()},
        scope="Actual AppKit synthetic keyDown and renderTick return, internal Metal readback; not physical HID/compositor present",runs=rows)
    if source_file.read_bytes()!=input_bytes: raise RuntimeError("GUI source fixture changed during measurement")
    (output/"summary.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print(output/"summary.json",flush=True)


if __name__=="__main__": main()
