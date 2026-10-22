#!/usr/bin/env python3
"""Checks selected release configuration; not a substitute for Organizer validation."""
import argparse
from pathlib import Path
import plistlib
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, help="Archived .app; otherwise checks source configuration")
args = parser.parse_args()
root = args.app or Path(__file__).resolve().parents[1] / "Configuration"
info = plistlib.loads((root / "Info.plist").read_bytes())
privacy = plistlib.loads((root / "PrivacyInfo.xcprivacy").read_bytes())
errors = []
for key in ["ResearchPrivacyPolicyURL", "ResearchSupportURL"]:
    value = urlparse(info.get(key, ""))
    if value.scheme != "https" or not value.hostname or value.hostname in ["example.com", "example.org"]:
        errors.append(f"{key}: supply a real publisher-owned HTTPS page.")
for key in ["NSMotionUsageDescription", "NSLocationWhenInUseUsageDescription"]:
    if not info.get(key): errors.append(f"Missing {key}.")
if info.get("UIBackgroundModes"): errors.append("Foreground recorder must not declare unnecessary background modes.")
if privacy.get("NSPrivacyTracking") or privacy.get("NSPrivacyCollectedDataTypes"):
    errors.append("Privacy declaration differs from this local-only implementation; review the release.")
if args.app:
    if info.get("CFBundleIdentifier", "").startswith("org.example"):
        errors.append("Replace the example bundle identifier with your own registered identifier.")
    if not list(root.glob("Assets.car")): errors.append("Compiled asset catalog was not found.")
if errors:
    print("RELEASE BLOCKERS\n" + "\n".join("- " + error for error in errors))
    raise SystemExit(1)
print("Checked configuration passed. Verify URLs, privacy labels, signing, screenshots, and real-device tests before submission.")
