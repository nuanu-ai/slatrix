#!/usr/bin/env python3
"""Checks that every capability spec/capabilities.json marks done on a platform has a test there that says
`capability: <id>`, that no test names an id the ledger lacks, and prints what each platform is missing."""
import json
import re
import sys
from pathlib import Path

TEST_FOLDERS = {"mac": ["Tests"], "android": ["android/app/src/test", "android/app/src/androidTest"]}
TAG = re.compile(r"//\s*capability:\s*([\w.-]+)")

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1])
capabilities = json.loads((root / "spec/capabilities.json").read_text(encoding="utf-8"))["capabilities"]
errors = []
ids = [entry.get("id") for entry in capabilities]
errors += [f"{id} is listed more than once" for id in sorted({id for id in ids if ids.count(id) > 1})]

tagged = {}
for platform, folders in TEST_FOLDERS.items():
    tagged[platform] = set()
    for folder in folders:
        for path in sorted((root / folder).rglob("*")):
            if path.suffix not in (".swift", ".kt"):
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                for id in TAG.findall(line):
                    tagged[platform].add(id)
                    if id not in ids:
                        errors.append(f"{path.relative_to(root)}:{number} names {id}, which spec/capabilities.json doesn't list")

for entry in capabilities:
    id = entry.get("id")
    if not id or not entry.get("what"):
        errors.append(f"{id or entry} needs an id and a what")
    for platform in TEST_FOLDERS:
        status = entry.get(platform)
        if status == "done" and id not in tagged[platform]:
            errors.append(f"{platform}: {id} is done but no test says capability: {id}")
        elif status != "done" and status != "missing" and not re.fullmatch(r"n/a: \S.*", status or ""):
            errors.append(f"{platform}: {id} is {status!r}, not done, missing or n/a: <reason>")

for platform in TEST_FOLDERS:
    missing = [entry for entry in capabilities if entry.get(platform) == "missing"]
    print(f"{platform} is missing {len(missing)}:")
    for entry in missing:
        print(f"  {entry['id']}  {entry.get('what')}")
for error in errors:
    print(f"error: {error}")
sys.exit(1 if errors else 0)
