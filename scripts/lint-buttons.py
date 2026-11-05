#!/usr/bin/env python3
"""Buttons the eye can't read: an icon alone needs a tooltip, and a face or name that opens a profile shows the
link cursor, as the timeline's do."""
import glob, re, sys

failed = False
for path in glob.glob("Sources/Slatrix/Views/**/*.swift", recursive=True):
    if "/DesignSystem/" in path:
        continue
    lines = open(path).read().split("\n")
    for start, line in enumerate(lines):
        if not re.search(r"\bButton\s*(\(action:[^)]*\))?\s*\{\s*$", line):
            continue
        end = next((i for i in range(start, min(start + 15, len(lines))) if ".buttonStyle" in lines[i]), None)
        if end is None:
            continue
        label = "\n".join(lines[start:end])
        modifiers = "\n".join(lines[end : end + 3])
        icon_only = "Image(systemName" in label and not re.search(r"\bText\(|\bLabel\(", label)
        if icon_only and ".help(" not in modifiers:
            print(f"{path}:{start + 1}: an icon-only button needs .help(_:)")
            failed = True
        if re.search(r"AvatarView\(|Text\(message\.senderName", label) and ".linkCursor()" not in modifiers:
            print(f"{path}:{start + 1}: a face or name that opens a profile needs .linkCursor()")
            failed = True
sys.exit(1 if failed else 0)
