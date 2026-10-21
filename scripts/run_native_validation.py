#!/usr/bin/env python3
"""Run the Debug native API harness without putting credentials in argv or logs."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import time

def sim(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], check=check, capture_output=True, text=True).stdout.strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--server", default="https://xbot.energylt.com")
    parser.add_argument("--credentials", default="~/xbot_user")
    parser.add_argument("--report", default="docs/live-validation.json")
    args = parser.parse_args()
    credentials = Path(args.credentials).expanduser().read_text().splitlines()
    if len(credentials) < 2: raise SystemExit("Credential file must contain two lines")
    sim("terminate", args.device, "dev.xbot.ios", check=False)
    sim("install", args.device, str(Path(args.app).resolve()))
    directory = Path(sim("get_app_container", args.device, "dev.xbot.ios", "data")) / "Documents"
    directory.mkdir(parents=True, exist_ok=True)
    secret = directory / "live-validation.json"
    result = directory / "native-validation-report.json"
    result.unlink(missing_ok=True)
    try:
        descriptor = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as file:
            json.dump({"server": args.server, "username": credentials[0].strip(), "password": credentials[1]}, file)
        credentials = None
        sim("launch", args.device, "dev.xbot.ios", "--validate-live")
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            if result.exists():
                report = json.loads(result.read_text())
                target = Path(args.report); target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
                print(json.dumps(report, ensure_ascii=False), flush=True)
                raise SystemExit(0 if report.get("passed") else 1)
            time.sleep(1)
        raise SystemExit("Native validation timed out; inspect the app's validation status")
    finally:
        secret.unlink(missing_ok=True)

if __name__ == "__main__": main()
