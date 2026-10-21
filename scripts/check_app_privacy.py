#!/usr/bin/env python3
"""Validate privacy/transport settings in the built artifact, not just sources."""
import argparse
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
args = parser.parse_args()
app = args.app
info = plistlib.loads((app / "Info.plist").read_bytes())
manifest = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
ats = info.get("NSAppTransportSecurity", {})
assert not ats.get("NSAllowsArbitraryLoads", False), "Global ATS bypass is forbidden"
assert not ats.get("NSAllowsArbitraryLoadsInWebContent", False), "Web content must not bypass ATS"
assert ats.get("NSAllowsLocalNetworking") is True, "Preserve explicit local-server connectivity"
assert manifest.get("NSPrivacyTracking") is False, "Tracking declaration must match this client"
reasons = {item["NSPrivacyAccessedAPIType"]: item["NSPrivacyAccessedAPITypeReasons"] for item in manifest["NSPrivacyAccessedAPITypes"]}
assert "CA92.1" in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", []), "Missing UserDefaults reason"
assert set(info.get("UIBackgroundModes", [])) <= {"fetch"}, "Only the implemented background-refresh mode is needed for alert push"
assert (app / "Mermaid/index.html").is_file(), "Offline diagrams must remain bundled"
assert (app / "Mermaid/mermaid.min.js").is_file(), "Offline Mermaid runtime missing"
print("PASS: built app includes privacy manifest, declared UserDefaults purpose, restricted ATS, background refresh and offline diagrams")
