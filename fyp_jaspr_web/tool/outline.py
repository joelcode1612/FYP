"""Print a structural outline (tags + classes) of a source HTML page's body."""
from __future__ import annotations

import re
import sys
from pathlib import Path

SRC = Path(r"C:\Users\Lenovo\WorkBuddy AI\new UI design")

VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}


def outline(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    body = re.search(r"<body[^>]*>(.*)</body>", text, flags=re.S | re.I)
    text = body.group(1) if body else text
    text = re.sub(r"<(script|style|svg)\b[^>]*>.*?</\1>", "", text, flags=re.S | re.I)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)

    lines: list[str] = []
    depth = 0
    pos = 0
    for m in re.finditer(r"<(/?)([a-zA-Z][\w:-]*)([^>]*?)(/?)>", text):
        # skip implicit closes; we only track explicit structure
        tag = m.group(2).lower()
        closing = m.group(1) == "/"
        attrs = m.group(3)
        selfclose = m.group(4) == "/"
        if closing:
            depth = max(0, depth - 1)
            continue
        cls = re.search(r'class="([^"]*)"', attrs)
        idm = re.search(r'id="([^"]*)"', attrs)
        cls_s = cls.group(1).strip() if cls else ""
        id_s = f"#{idm.group(1)}" if idm else ""
        # collapse long class lists
        if len(cls_s) > 90:
            cls_s = cls_s[:87] + "..."
        lines.append(f"{'  ' * depth}<{tag}{id_s}{(' .' + cls_s.replace(' ', ' .')) if cls_s else ''}>")
        if tag not in VOID and not selfclose:
            depth += 1
        pos = m.end()
    return "\n".join(lines)


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        p = SRC / arg
        print("=" * 78)
        print(arg)
        print("=" * 78)
        print(outline(p))
        print()
