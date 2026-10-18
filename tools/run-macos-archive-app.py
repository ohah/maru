"""Launch one archive smoke process; keep storage failures distinct from startup failures."""
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parent / 'shared-restore-app'))
from gui_launch import GUIApp


def main():
    app, output = (Path(arg).resolve() for arg in sys.argv[1:])
    env = os.environ.copy()
    output.mkdir(parents=True, exist_ok=True)
    process = None
    gui = env.get('MARU_AGENT_SESSION_ARCHIVE_GUI') == '1'
    try:
        if gui:
            process = GUIApp(app, env, output, stage_root=output.parent.parent / 'gui-stage')
            code = process.wait(timeout=25)
        else:
            with (output / 'app.stdout.txt').open('wb') as stdout, (output / 'app.stderr.txt').open('wb') as stderr:
                process = subprocess.Popen([str(app)], env=env, stdout=stdout, stderr=stderr)
                code = process.wait(timeout=25)
        log = (output / 'app.stderr.txt').read_text(errors='replace')
        # open -W reports the LaunchServices waiter result, not the application's exit code.
        # Summary assertions remain mandatory; explicit capture errors must fail even if it exits 0.
        if 'MARU_SCREENSHOT: PPM 쓰기 실패' in log:
            print('archive smoke: capture I/O failure; see ' + str(output / 'app.stderr.txt'), file=sys.stderr)
            return 1
        return code
    except subprocess.TimeoutExpired:
        print('archive smoke: application timeout; see ' + str(output), file=sys.stderr)
        return 1
    finally:
        if process is not None:
            if gui:
                try:
                    if process.poll() is None:
                        process.kill()
                finally:
                    process.close()
            elif process.poll() is None:
                process.kill()
                process.wait(timeout=5)


if __name__ == '__main__':
    sys.exit(main())
