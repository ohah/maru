"""전체 cohort 전 실제 frame label과 surface schema를 확인하는 1 pair 예비 수집이다."""
import argparse
import json
import shutil
from pathlib import Path
import external_display_trace as trace
import external_display_report as report
import run
import verify


def main():
    p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    build,output=a.build.resolve(),a.output.resolve();repository=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repository and repository not in output.parents,'new external pilot output required')
    source=json.loads((build/'source.json').read_text())
    verify.require(source.get('external_display_trace') is True and source.get('submit_display') is True and not source.get('display_timing',False),'labelled build without display-link observer required')
    verify.require(not any(source.get(n,False) for n in ('frame_wake_control','target_frame_control','observer_cpu','deferred_retry_control','observer_posts_control','observer_work_control')),'unchanged product scheduling required')
    verify.require(verify.sha(build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app')==source['app_sha256'],'pilot binary drift')
    output.mkdir(mode=0o700)
    (output/'source.json').write_text(json.dumps(source,indent=2)+'\n')
    tools=[p for p in Path(__file__).parent.iterdir() if p.suffix in ('.py','.inc')]
    hashes={p.name:verify.sha(p) for p in tools}
    (output/'tools').mkdir()
    for p in tools:shutil.copy2(p,output/'tools'/p.name)
    (output/'tool-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
    results={}
    for mode in ('disabled','enabled'):
        target=output/mode;print(mode,flush=True)
        meta=run.trial(build,target,50000,'async','typing',50,30,'normal',0,observer=trace.Marker(mode),fixture_kind='multiline',fold_reuse_control='prepared')
        verify.require(meta['error'] is None,'external pilot invalid: '+str(meta['error']))
        results[mode]=report.analyze(target)
        (target/'external-display.json').write_text(json.dumps(results[mode],indent=2)+'\n')
    verify.require(all(verify.sha(Path(__file__).parent/name)==digest for name,digest in hashes.items()),'pilot tools changed')
    (output/'pilot.json').write_text(json.dumps(dict(kind='external-display-pilot',complete=True,source=source,runs=results),indent=2)+'\n')
    print(output,flush=True)


if __name__=='__main__':main()
