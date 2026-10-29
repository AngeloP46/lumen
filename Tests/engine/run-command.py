"""Run an engine case; a bounded crash diagnostic must keep its exact arguments/status."""
import os
import signal
import subprocess
import sys


def run_command(command, debugger=("lldb",), timeout=90):
    result = subprocess.run(command, check=False)
    code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    print(f"engine-test exit code: {code}", flush=True)
    if code <= 1:
        return code
    print("::group::lldb backtrace (same engine case, at most 90 seconds)", flush=True)
    try:
        with subprocess.Popen(
            [*debugger, "-b", "-o", "run", "-o", "bt 25", "--", *command],
            start_new_session=True,
        ) as process:
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                # The engine launched by lldb belongs to this new process group too.
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                print("Crash diagnostic timed out; keeping the original failure.", flush=True)
    except OSError as error:
        print(f"Crash diagnostic unavailable: {error}", flush=True)
    finally:
        print("::endgroup::", flush=True)
    return code


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: run-command.py ENGINE [ARGUMENT ...]")
    sys.exit(run_command(sys.argv[1:]))
