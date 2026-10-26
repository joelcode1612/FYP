"""CSS sanity checks: brace balance, duplicate selectors, unresolved var() refs."""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

CSS = Path(__file__).resolve().parents[1] / "web" / "styles.css"


def main() -> int:
    text = CSS.read_text(encoding="utf-8")
    stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.S)

    opens = stripped.count("{")
    closes = stripped.count("}")
    print(f"braces: {opens} open / {closes} close -> {'BALANCED' if opens == closes else 'MISMATCH'}")

    # selectors at rule level (including inside @media)
    selectors: list[str] = []
    media_selectors: list[str] = []
    buf = ""
    i = 0
    n = len(stripped)
    media_depth = 0
    while i < n:
        ch = stripped[i]
        if ch == "{":
            sel = " ".join(buf.split())
            buf = ""
            if sel.startswith("@"):
                media_depth += 1
                i += 1
                continue
            (media_selectors if media_depth else selectors).append(sel)
            depth = 1
            i += 1
            while i < n and depth:
                if stripped[i] == "{":
                    depth += 1
                elif stripped[i] == "}":
                    depth -= 1
                i += 1
            continue
        if ch == "}":
            if media_depth:
                media_depth -= 1
            buf = ""
            i += 1
            continue
        buf += ch
        i += 1

    dupes = [s for s, c in Counter(selectors).items() if c > 1]
    media_dupes = [s for s, c in Counter(media_selectors).items() if c > 1]
    print(
        f"rules: {len(selectors)} top-level + {len(media_selectors)} in @media; "
        f"top-level duplicates: {len(dupes)}; media-block duplicates: {len(media_dupes)}"
    )
    for d in dupes:
        print("  DUP  " + d)
    for d in media_dupes:
        print("  DUP-in-media  " + d + "  (expected: a base rule plus its breakpoint)")

    defined = set(re.findall(r"(--[\w-]+)\s*:", stripped))
    used = set(re.findall(r"var\(\s*(--[\w-]+)", stripped))
    missing = sorted(used - defined)
    print(f"tokens: {len(defined)} defined, {len(used)} used, {len(missing)} missing")
    for m in missing:
        print("  MISSING  " + m)
    unused = sorted(defined - used)
    if unused:
        print("  unused: " + " ".join(unused))

    # hex literals outside :root (the design system forbids them in component rules)
    root_end = stripped.find("}", stripped.find(":root"))
    body = stripped[root_end:]
    hexes = Counter(re.findall(r"#[0-9a-fA-F]{3,8}\b", body))
    print(f"hex literals outside :root: {sum(hexes.values())} across {len(hexes)} values")
    return 0 if opens == closes and not missing else 1


if __name__ == "__main__":
    sys.exit(main())
