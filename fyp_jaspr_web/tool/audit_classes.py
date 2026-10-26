"""Class-coverage audit: source design HTML/CSS vs Jaspr target Dart/CSS.

Three passes:
  A. strict  - class tokens passed to `classes:` in Dart (interpolation-aware)
  B. loose   - any quoted string in Dart that looks like a class list
  C. source  - class="..." attributes plus JS class strings in the HTML pages

Reports missing CSS rules, dead CSS rules, and source-only vocabulary.
"""
from __future__ import annotations

import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = Path(r"C:\Users\Lenovo\WorkBuddy AI\new UI design")
TARGET_CSS = ROOT / "web" / "styles.css"
TARGET_LIB = ROOT / "lib"

CLASS_ATTR = re.compile(r'class="([^"]+)"')
QUOTED = re.compile(r"'([^'\\\n]*)'|\"([^\"\\\n]*)\"")
TOKENLIST = re.compile(r"^[a-z][a-z0-9_-]*(?:\s+[a-z][a-z0-9_-]*)*$")
IDENT = re.compile(r"^[a-z][a-z0-9_-]*$")


def css_selectors(css: str) -> set[str]:
    """Every class name appearing in a selector, including inside @media blocks."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    out: set[str] = set()
    buf = ""
    i = 0
    n = len(css)
    while i < n:
        ch = css[i]
        if ch == "{":
            sel = buf.strip()
            buf = ""
            if sel.startswith("@"):
                # at-rule: keep parsing its body at the same level
                i += 1
                continue
            out |= set(re.findall(r"\.(-?[A-Za-z_][\w-]*)", sel))
            # skip the declaration block
            depth = 1
            i += 1
            while i < n and depth:
                if css[i] == "{":
                    depth += 1
                elif css[i] == "}":
                    depth -= 1
                i += 1
            continue
        if ch == "}":
            buf = ""
            i += 1
            continue
        buf += ch
        i += 1
    return out


def split_classes(s: str) -> set[str]:
    """Strip Dart interpolation and split into identifiers."""
    s = re.sub(r"\$\{[^}]*\}", " ", s)
    s = re.sub(r"\$[A-Za-z_]\w*", " ", s)
    return {t for t in s.split() if IDENT.match(t)}


def strict_dart_classes(dart: str) -> set[str]:
    """Tokens in the expression following `classes:`."""
    out: set[str] = set()
    for m in re.finditer(r"classes:\s*", dart):
        i = m.end()
        depth = 0
        j = i
        while j < len(dart):
            ch = dart[j]
            if ch in "[(":
                depth += 1
            elif ch in "])":
                if depth == 0:
                    break
                depth -= 1
            elif ch == "," and depth == 0:
                break
            j += 1
        span = dart[i:j]
        for q in QUOTED.finditer(span):
            out |= split_classes(q.group(1) or q.group(2) or "")
    return out


def loose_dart_classes(dart: str) -> set[str]:
    out: set[str] = set()
    for q in QUOTED.finditer(dart):
        s = q.group(1) or q.group(2) or ""
        if TOKENLIST.match(s):
            out |= set(s.split())
    return out


def main() -> int:
    src_html_classes: Counter[str] = Counter()
    src_pages: dict[str, set[str]] = {}
    for f in sorted(SRC.rglob("*.html")):
        text = f.read_text(encoding="utf-8", errors="replace")
        # Static markup only: script/style blocks build DOM at runtime and would
        # otherwise pollute the class set with JS expression fragments.
        static = re.sub(
            r"<(script|style)\b[^>]*>.*?</\1>", "", text, flags=re.S | re.I
        )
        cls: set[str] = set()
        for m in CLASS_ATTR.finditer(static):
            cls |= set(m.group(1).split())
        # JS-built class names: classList.add('is-on'), className = 'badge x'
        for m in re.finditer(
            r"(?:classList\.(?:add|toggle|remove)|className\s*=|classList\.contains)\s*\(?\s*['\"]([^'\"]+)['\"]",
            text,
        ):
            cls |= set(m.group(1).split())
        src_pages[str(f.relative_to(SRC))] = cls
        src_html_classes.update(cls)

    src_css: set[str] = set()
    for f in SRC.rglob("*.css"):
        src_css |= css_selectors(f.read_text(encoding="utf-8", errors="replace"))

    target_css = css_selectors(TARGET_CSS.read_text(encoding="utf-8"))

    strict: Counter[str] = Counter()
    loose: set[str] = set()
    per_file: dict[str, set[str]] = {}
    for f in sorted(TARGET_LIB.rglob("*.dart")):
        text = f.read_text(encoding="utf-8")
        s = strict_dart_classes(text)
        per_file[str(f.relative_to(TARGET_LIB))] = s
        strict.update(s)
        loose |= s | loose_dart_classes(text)

    print("=" * 78)
    print("1. CLASSES EMITTED BY DART WITH NO CSS RULE  (renders unstyled)")
    print("=" * 78)
    missing = sorted(c for c in strict if c not in target_css)
    print(f"   {len(missing)} of {len(strict)}")
    for c in missing:
        files = [f for f, s in per_file.items() if c in s]
        print(f"   .{c:<32} {', '.join(files)}")

    print()
    print("=" * 78)
    print("2. CSS CLASSES NEVER REFERENCED ANYWHERE IN lib/  (dead rules)")
    print("=" * 78)
    dead = sorted(c for c in target_css if c not in loose)
    print(f"   {len(dead)} of {len(target_css)}")
    for c in dead:
        print(f"   .{c}")

    print()
    print("=" * 78)
    print("3. SOURCE-HTML CLASSES WITH NO TARGET CSS RULE")
    print("=" * 78)
    src_only = sorted(c for c in src_html_classes if c not in target_css)
    print(f"   {len(src_only)} of {len(src_html_classes)}")
    for c in src_only:
        n = len([p for p, s in src_pages.items() if c in s])
        print(f"   .{c:<30} {src_html_classes[c]:>3}x in {n} page(s)")

    print()
    print("=" * 78)
    print("4. SOURCE-CSS CLASSES WITH NO TARGET CSS RULE")
    print("=" * 78)
    css_only = sorted(c for c in src_css if c not in target_css)
    print(f"   {len(css_only)} of {len(src_css)}")
    print("   " + " ".join("." + c for c in css_only))
    return 0


if __name__ == "__main__":
    sys.exit(main())
