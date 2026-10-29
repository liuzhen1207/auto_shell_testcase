"""Watch a running ``rcdn run`` and freeze the scene the moment a replica difference is reported.

Why this exists: ``rcdn run`` resets the cluster (stop -> wipe -> configure -> start) before **each** case, so a
difference found in case N is destroyed the moment case N+1 begins. Answering "where did the row go" needs the
**on-disk** state of every replica (WAL + TsFile) exactly as the verdict found it, so this watcher:

1. polls ``<results>/cases/*/result.json`` for the first ``replica inconsistency`` verdict (a 305-only FAIL does
   not trigger it -- that failure never loses data);
2. stops the run's process group and any local benchmark writers (the load has already finished by then);
3. copies the case directory aside and writes a marker, then exits.

The cluster is left untouched, so the next step is the forensic one: compare every replica's WAL/TsFile for the
exact ``(device, time)`` the sentinel named.

Usage::

    PYTHONPATH=scripts python3 -m rcdn.freeze_on_diff <run_pid> <results_dir> [--poll SECONDS] [--out DIR] [--conf CONF] [--no-kill-writers]
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import signal
import sys
import time


def _benchmark_pids() -> list[int]:
    pids = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmd = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if "iot-benchmark" in cmd or "benchmark.core" in cmd:
            pids.append(int(entry.name))
    return pids


def _tree_pids(root: int) -> list[int]:
    """The target process and its descendants, children first. Never touches process groups.

    killpg() is wrong here: a background job started from a non-interactive shell shares that shell's process
    group, so killpg(target) can take out the caller's own shell (measured -- it killed this tool's test harness).
    """
    order: list[int] = []
    stack = [root]
    while stack:
        cur = stack.pop()
        order.append(cur)
        try:
            kids = pathlib.Path(f"/proc/{cur}/task/{cur}/children").read_text().split()
        except OSError:
            kids = []
        stack.extend(int(k) for k in kids)
    return list(reversed(order))


def _is_replica_diff(result: pathlib.Path) -> tuple[bool, str]:
    try:
        data = json.loads(result.read_text())
    except (OSError, ValueError):
        return False, ""
    blob = json.dumps(data, ensure_ascii=False)
    if "replica" in blob and ("differ" in blob or "inconsist" in blob):
        return True, blob[:400]
    return False, ""


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    pid, results = int(argv[0]), pathlib.Path(argv[1])
    poll = 20.0
    out = results.parent / "frozen"
    if "--poll" in argv:
        poll = float(argv[argv.index("--poll") + 1])
    if "--out" in argv:
        out = pathlib.Path(argv[argv.index("--out") + 1])
    out.mkdir(parents=True, exist_ok=True)
    print(f"  watching pid={pid} results={results} poll={poll}s", flush=True)

    seen: dict[str, str] = {}
    while True:
        for result in sorted(results.glob("cases/*/result.json")):
            if result.parent.name in seen:
                continue
            hit, blob = _is_replica_diff(result)
            seen[result.parent.name] = "DIFF" if hit else "ok"
            if not hit:
                continue
            stamp = time.strftime("%H:%M:%S")
            print(f"  {stamp} ★ replica difference in {result.parent.name}: {blob}", flush=True)
            # Give the harness a moment to finish its own FAIL log backup.  It tars the
            # DataNode logs into results/<run>/log_backup/<case>_<stamp>/ at case end, and
            # SIGTERM sent while that tar runs leaves an EMPTY backup directory -- measured
            # on dn_remove_restart_sweep#4, whose DN logs were then wiped by the next case's
            # prepare, so the row-level trace of a real replica diff was lost.
            backup_root = result.parents[2] / "log_backup"
            deadline = time.time() + 90
            while time.time() < deadline:
                done = [d for d in backup_root.glob(f"{result.parent.name}_*") if (d / "DONE").is_file()]
                if done:
                    print(f"  harness log backup ready: {done[0].name}", flush=True)
                    break
                time.sleep(3)
            else:
                print("  no harness log backup after 90s; freezing anyway", flush=True)
            tree = _tree_pids(pid)
            for target in tree:
                try:
                    os.kill(target, signal.SIGTERM)
                except OSError:
                    pass
            time.sleep(2)
            for target in tree:
                try:
                    os.kill(target, signal.SIGKILL)
                except OSError:
                    pass
            killed = []
            for bpid in ([] if "--no-kill-writers" in argv else _benchmark_pids()):
                try:
                    os.kill(bpid, signal.SIGKILL)
                    killed.append(bpid)
                except OSError:
                    pass
            aside = out / f"FROZEN_{result.parent.name}"
            shutil.rmtree(aside, ignore_errors=True)
            shutil.copytree(result.parent, aside)
            (out / "FROZEN.json").write_text(
                json.dumps(
                    {
                        "case": result.parent.name,
                        "when": time.strftime("%Y-%m-%d %H:%M:%S"),
                        "result": blob,
                        "run_pid": pid,
                        "killed_writers": killed,
                        "copied_to": str(aside),
                    },
                    ensure_ascii=False,
                    indent=2,
                )
            )
            print(f"  scene frozen: run stopped, writers killed {killed}, copy at {aside}", flush=True)
            if "--conf" in argv:
                import subprocess

                conf = argv[argv.index("--conf") + 1]
                env = dict(os.environ)
                env["PYTHONPATH"] = str(pathlib.Path(__file__).resolve().parents[1])
                print("  collecting on-disk evidence ...", flush=True)
                subprocess.run(
                    [
                        sys.executable, "-m", "rcdn.collect_freeze_evidence", conf,
                        "--out", str(aside / "evidence"),
                        "--device", f"<see sentinel captures under {result.parent}>",
                    ],
                    env=env,
                    check=False,
                )
            return 0
        if not os.path.exists(f"/proc/{pid}"):
            print("  run process exited; nothing to freeze", flush=True)
            return 1
        time.sleep(poll)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
