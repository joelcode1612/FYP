#!/usr/bin/env python3
"""
Generate the .lnd-scoped landing stylesheet from the original source page.

Source:  C:/Users/Lenovo/WorkBuddy AI/new UI design/sitewise-roles/index.html
         (inline <style> block)

Output:  web/_landing_port.css

Design rules (why this exists -- the previous generator corrupted the CSS):
  * NEVER minify. Whitespace inside selectors is significant: `.scene-copy h1`
    (descendant) and `.scene-copyh1` (one class) are completely different rules.
    The old port stripped those spaces, so hundreds of rules never matched.
  * Never strip spaces inside declaration values: `inset: 74px 0 0 0` is valid,
    `inset:74px000` is invalid and the whole declaration gets dropped.
  * Scope by wrapping in `.lnd { ... }` and relying on NATIVE CSS NESTING, so
    the browser prepends `.lnd` to every descendant selector. No per-selector
    rewriting, so no combinators can be lost.
  * Custom properties are renamed `--x` -> `--lnd-x` so the landing palette
    cannot collide with the app's own token namespace.
  * At-rules that must stay global (@keyframes, @property, @font-face) are
    hoisted out of the wrapper, because nesting them is invalid and animation
    names are not scoped.
"""

import re
import sys
from pathlib import Path

SRC = Path(r"C:/Users/Lenovo/WorkBuddy AI/new UI design/sitewise-roles/index.html")
OUT = Path(__file__).resolve().parent.parent / "web" / "_landing_port.css"

VAR_RE = re.compile(r"--([A-Za-z0-9_-]+)")


def rename_vars(text: str) -> str:
    """Rename every custom property `--x` to `--lnd-x` (declarations + var())."""
    return VAR_RE.sub(r"--lnd-\1", text)


def extract_style(html: str) -> str:
    start = html.index("<style>") + len("<style>")
    end = html.index("</style>", start)
    return html[start:end]


def split_top_level(css: str):
    """Split CSS into top-level rules, honouring comments, strings and braces.

    Returns a list of raw rule texts, e.g. ".a { ... }" or "@media x { ... }".
    """
    out = []
    i, n, depth, start = 0, len(css), 0, 0
    while i < n:
        c = css[i]
        if c == "/" and i + 1 < n and css[i + 1] == "*":
            j = css.find("*/", i + 2)
            i = (j + 2) if j != -1 else n
            continue
        if c in "\"'":
            quote = c
            i += 1
            while i < n:
                if css[i] == "\\":
                    i += 2
                    continue
                if css[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                out.append(css[start:i + 1])
                start = i + 1
        i += 1
    tail = css[start:]
    if tail.strip():
        out.append(tail)
    return out


def split_prelude(rule: str):
    """Return (prelude, body) for a top-level rule text."""
    i, n, depth = 0, len(rule), 0
    while i < n:
        c = rule[i]
        if c == "/" and i + 1 < n and rule[i + 1] == "*":
            j = rule.find("*/", i + 2)
            i = (j + 2) if j != -1 else n
            continue
        if c in "\"'":
            quote = c
            i += 1
            while i < n:
                if rule[i] == "\\":
                    i += 2
                    continue
                if rule[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            if depth == 0:
                prelude = rule[:i]
                body = rule[i + 1:]
                if body.rstrip().endswith("}"):
                    body = body.rstrip()[:-1]
                return prelude, body
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    return rule, ""


GLOBAL_AT_RULES = ("@keyframes", "@property", "@font-face", "@page", "@charset")
NESTED_AT_RULES = ("@media", "@supports", "@container", "@layer")


def main() -> int:
    html = SRC.read_text(encoding="utf-8")
    css = extract_style(html)

    # Drop @import (the Archivo webfont is already loaded by the Jaspr app).
    css = re.sub(r"@import\s+[^;]+;", "", css)

    global_rules = []   # emitted outside the .lnd wrapper
    scoped_rules = []   # emitted inside the .lnd wrapper
    stats = {"root": 0, "body": 0, "html": 0, "global_at": 0, "nested_at": 0, "plain": 0}

    for rule in split_top_level(css):
        stripped = rule.strip()
        if not stripped:
            continue
        prelude, body = split_prelude(rule)
        p = prelude.strip()

        low = p.lower()
        if low.startswith(GLOBAL_AT_RULES):
            global_rules.append(rename_vars(stripped))
            stats["global_at"] += 1
        elif low.startswith(NESTED_AT_RULES):
            scoped_rules.append(rename_vars(stripped))
            stats["nested_at"] += 1
        elif p == ":root":
            global_rules.append(rename_vars(stripped))
            stats["root"] += 1
        elif p == "html":
            # The app's own stylesheet already sets html { scroll-behavior:
            # smooth; scroll-padding-top: 88px; } -- skip to avoid a conflict.
            stats["html"] += 1
        elif p == "body":
            # Re-target the page-level body typography/colour onto the .lnd
            # wrapper itself. `overflow-x: hidden` is deliberately dropped: on a
            # block element it forces overflow-y to `auto`, turning the landing
            # into a scroll container and breaking sticky positioning.
            decls = []
            for decl in body.split(";"):
                if decl.strip().startswith("overflow-x"):
                    continue
                decls.append(decl)
            body = ";".join(decls)
            # Must live INSIDE the .lnd wrapper: `&` resolves to `.lnd` there.
            scoped_rules.append("& {\n" + rename_vars(body) + "\n}")
            stats["body"] += 1
        else:
            scoped_rules.append(rename_vars(stripped))
            stats["plain"] += 1

    parts = [
        "/* PORTED LANDING CSS (sitewise-roles) -- generated by tool/gen_landing_css.py.",
        "   Do NOT hand-edit: regenerate from the source page instead.",
        "",
        "   Scoped with NATIVE CSS NESTING under `.lnd`, so every nested rule",
        "   becomes `.lnd <selector>` and cannot leak into the rest of the app.",
        "   Custom properties are renamed to `--lnd-*` to avoid colliding with",
        "   the app's own token namespace. @keyframes/@property stay global",
        "   because animation names are not scoped.",
        "*/",
        "",
    ]
    if global_rules:
        parts.append("/* ---- global (must not be scoped) ---- */")
        parts.extend(global_rules)
        parts.append("")
    parts.append("/* ---- landing-scoped rules ---- */")
    parts.append(".lnd {")
    parts.extend(scoped_rules)
    parts.append("}")

    text = "\n".join(parts) + "\n"
    OUT.write_text(text, encoding="utf-8")

    print(f"wrote {OUT} ({len(text)} bytes)")
    print("stats:", stats)
    print("scoped rules:", len(scoped_rules), " global rules:", len(global_rules))

    # --- self-checks -------------------------------------------------------
    problems = []
    for bad, label in [
        (".scene-copyh1", "descendant selector collapsed"),
        (".brandsmall", "descendant selector collapsed"),
        (".scene-uia", "descendant selector collapsed"),
        ("inset:74px", "declaration value spaces stripped"),
        ("024px80px", "shadow value spaces stripped"),
        ("'SegoeUI'", "font stack spaces stripped"),
    ]:
        if bad in text:
            problems.append(f"corruption marker still present: {bad} ({label})")
    for good, label in [
        (".scene-copy h1", "descendant selector preserved"),
        (".brand small", "descendant selector preserved"),
        ("inset: 74px 0 0 0", "declaration value spaces preserved"),
        ("--lnd-terracotta", "tokens renamed"),
        (".lnd {", "wrapper present"),
    ]:
        if good not in text:
            problems.append(f"expected content missing: {good} ({label})")

    # Every var() reference must point at a renamed token.
    for ref in set(re.findall(r"var\(\s*(--[A-Za-z0-9_-]+)", text)):
        if not ref.startswith("--lnd-"):
            problems.append(f"un-renamed token reference: {ref}")

    # The `&` (body) rule must be nested inside the .lnd wrapper, not global.
    idx_wrapper = text.index(".lnd {")
    if "& {" in text and text.index("& {") < idx_wrapper:
        problems.append("`&` rule emitted outside the .lnd wrapper")

    if problems:
        print("\nSELF-CHECK PROBLEMS:")
        for p in problems:
            print("  -", p)
        return 1
    print("\nself-checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
