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
    parser.add_argument("--consent-to-ai-sharing", action="store_true", help="Explicitly authorize the test messages and image being sent to your server's configured AI/tools")
    parser.add_argument("--ai-recipients", default="", help="Actual AI/proxy recipients you verified in your server configuration")
    parser.add_argument("--local-models-only", action="store_true")
    args = parser.parse_args()
    if not args.consent_to_ai_sharing or (not args.local_models_only and not args.ai_recipients.strip()):
        parser.error("Verify your configured recipients, then pass --consent-to-ai-sharing and --ai-recipients (or --local-models-only)")
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
            json.dump({"server": args.server, "username": credentials[0].strip(), "password": credentials[1], "consent_to_ai_sharing": args.consent_to_ai_sharing, "ai_recipients": args.ai_recipients, "local_models_only": args.local_models_only}, file)
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
