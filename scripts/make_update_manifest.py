#!/usr/bin/env python3
"""Write an iOS-only manifest after a build is available on App Store/TestFlight."""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--version', required=True)
parser.add_argument('--build', type=int, required=True)
parser.add_argument('--url', required=True)
parser.add_argument('--changelog', default='')
parser.add_argument('--mandatory', action='store_true')
parser.add_argument('--output', default='build/ios/latest.json')
args = parser.parse_args()
url = urlsplit(args.url)
if args.build <= 0 or url.scheme != 'https' or url.hostname not in ('apps.apple.com', 'testflight.apple.com') or url.username or url.password:
    parser.error('Use a positive build number and an HTTPS App Store/TestFlight URL')
target = Path(args.output)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps({'platform': 'ios', 'versionName': args.version, 'versionCode': args.build, 'url': args.url, 'changelog': args.changelog, 'mandatory': args.mandatory}, ensure_ascii=False, indent=2) + '\n')
print(target)
