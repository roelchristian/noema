#!/usr/bin/env python3
"""Opt-in SIGKILL acceptance for synthetic ENT04–05 fixtures; never power-loss proof.

Build the matching standard VaultCoreTests graph first. This controller launches
one worker at a time, kills only its attested PID, then starts a fresh verifier.
All fixtures and diagnostics are retained in a pinned managed evidence run.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid


REPO = Path(__file__).resolve().parents[1]
CASES = [(action, phase) for action in ("save", "reorder", "link", "unlink")
         for phase in ("precommit", "postack")]
CASES += [(action, phase) for action in ("migrate8", "migrate9")
          for phase in ("precommit", "before-manifest", "after-manifest")]


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def stop_owned_group(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


def execute_case(run, action, phase, timeout):
    name = f"{action}-{phase}"
    directory = run / name
    directory.mkdir()
    token = str(uuid.uuid4())
    environment = os.environ.copy()
    environment.update(NOEMA_ENTITY_BRIDGE_CRASH="1", NOEMA_CRASH_CASE_DIR=str(directory),
                       NOEMA_CRASH_TOKEN=token, NOEMA_CRASH_MODE="crash",
                       NOEMA_CRASH_ACTION=action, NOEMA_CRASH_PHASE=phase)
    command = ["./scripts/test.sh", "standard", "--targets", "VaultCoreTests",
               "--skip-build", "--skip-update", "--filter", "entityBridgeProcessCrashWorker"]
    result = {"case": name, "command": command, "status": "running", "token": token}
    write_json(directory / "result.json", result)
    with (directory / "worker.log").open("w") as output:
        process = subprocess.Popen(command, cwd=REPO, env=environment, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + timeout
            marker = directory / "ready.json"
            while not marker.exists():
                if process.poll() is not None:
                    raise RuntimeError(f"worker exited {process.returncode} before crash barrier")
                if time.monotonic() >= deadline:
                    raise TimeoutError("worker did not reach the bounded crash barrier")
                time.sleep(0.05)
            ready = json.loads(marker.read_text())
            if ready.get("token") != token or ready.get("phase") != phase:
                raise RuntimeError("crash barrier identity mismatch")
            pid = int(ready["pid"])
            if pid <= 1 or pid == os.getpid() or os.getpgid(pid) != process.pid:
                raise RuntimeError("worker PID is outside the controller-owned process group")
            result["worker_pid"] = pid
            result["barrier"] = ready
            wal = directory / "Vault" / "blocks.sqlite-wal"
            result["wal_bytes_at_barrier"] = wal.stat().st_size if wal.exists() else 0
            write_json(directory / "result.json", result)
            os.kill(pid, signal.SIGKILL)
            result["signal"] = "SIGKILL"
            result["worker_wrapper_exit"] = process.wait(timeout=timeout)
            if result["worker_wrapper_exit"] == 0:
                raise RuntimeError("SIGKILL worker unexpectedly reported success")
            write_json(directory / "result.json", result)
        finally:
            stop_owned_group(process)
    environment["NOEMA_CRASH_MODE"] = "verify"
    with (directory / "verifier.log").open("w") as output:
        verifier = subprocess.Popen(command, cwd=REPO, env=environment, stdout=output,
                                    stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result["verifier_exit"] = verifier.wait(timeout=timeout)
        finally:
            stop_owned_group(verifier)
    if result["verifier_exit"] != 0:
        raise RuntimeError(f"fresh-process verifier exited {result['verifier_exit']}")
    verified = json.loads((directory / "verified.json").read_text())
    if verified.get("status") != "passed" or verified.get("case") != name:
        raise RuntimeError("fresh-process verification acknowledgement is missing or wrong")
    result.update(status="passed", verification=verified)
    write_json(directory / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", default="entity-bridge-crash-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    parser.add_argument("--case", choices=[f"{a}-{p}" for a, p in CASES], action="append",
                        help="Run selected cases only; omission runs all 14.")
    parser.add_argument("--timeout", type=int, default=45, help="Bound each worker/verifier phase in seconds (10–60).")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}", args.run_id):
        parser.error("run-id must be a simple managed-evidence name")
    if not 10 <= args.timeout <= 60:
        parser.error("timeout must be between 10 and 60 seconds")
    stamp = REPO / ".build/noema-test-graph"
    if not stamp.is_file() or stamp.read_text().strip() != "standard:debug:VaultCoreTests":
        parser.error("first successfully build/run ./scripts/test.sh standard --targets VaultCoreTests --skip-update --filter entityBridgeProcessCrashWorker")
    run = REPO / ".local/agent-runs" / args.run_id
    run.mkdir(parents=True, exist_ok=False)
    (run / ".active").touch()
    (run / ".pinned").touch()
    selected = [(a, p) for a, p in CASES if not args.case or f"{a}-{p}" in args.case]
    results = []
    summary = {"status": "running", "power_loss_proven": False, "results": results,
               "scope": "Synthetic fixture process termination at named transaction/publication barriers"}
    try:
        for action, phase in selected:
            try:
                result = execute_case(run, action, phase, args.timeout)
                print(f"PASS {result['case']}", flush=True)
            except Exception as error:
                result_path = run / f"{action}-{phase}" / "result.json"
                result = json.loads(result_path.read_text()) if result_path.exists() else {"case": f"{action}-{phase}"}
                result.update(status="failed", error=str(error))
                write_json(result_path, result)
                write_json(run / result["case"] / "failure.json", result)
                print(f"FAIL {result['case']}: {error}", flush=True)
            results.append(result)
            write_json(run / "summary.json", summary)
        summary["status"] = "passed" if all(r["status"] == "passed" for r in results) else "failed"
    except BaseException as error:
        summary.update(status="failed", interrupted=str(error))
        raise
    finally:
        write_json(run / "summary.json", summary)
        if summary["status"] != "passed":
            (run / ".failed").touch()
        (run / ".complete").touch()
        (run / ".active").unlink()
        print(f"Evidence: {run}", flush=True)
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
