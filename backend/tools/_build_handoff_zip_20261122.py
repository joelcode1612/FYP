"""One-shot packer for the PROJECT1 session handoff ZIP. Not a verification harness."""
from __future__ import annotations

import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # FYP/backend
FYP = ROOT.parent
DELIV = FYP / "deliverables"
OUT = DELIV / "PROJECT1_HANDOFF_PACKAGE_20261122.zip"

# Files are stored with paths relative to FYP so a new session can unzip in place.
paths: list[Path] = []

# 1. Handoff + full deliverables tree (documents + evidence).
paths.append(DELIV / "PROJECT1_SESSION_HANDOFF_20261122.md")
for p in sorted(DELIV.rglob("*")):
    if not p.is_file() or p == OUT:
        continue
    if "gstack" in p.parts:
        continue  # unrelated prior work
    paths.append(p)

# 2. All harness tools + wrapper.
for p in sorted((ROOT / "tools").iterdir()):
    if p.is_file() and (p.suffix in {".py", ".cmd"}):
        paths.append(p)

# 3. Optional raw transcript for provenance.
TRANSCRIPT = Path(
    r"C:\Users\HP\.workbuddy-ai\projects\c-Users-HP-WorkBuddy AI-2026-11-21-16-10-32"
    r"\3e589d2b-3874-495a-9195-18c437a8352a.jsonl"
)
if TRANSCRIPT.exists():
    paths.append(TRANSCRIPT)

# De-duplicate, preserve order.
seen: set[str] = set()
unique: list[Path] = []
for p in paths:
    key = str(p).lower()
    if key not in seen:
        seen.add(key)
        unique.append(p)

OUT.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(OUT, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for p in unique:
        if p == TRANSCRIPT:
            arc = "00_TRANSCRIPT_OPTIONAL/session_20261121.jsonl"
        else:
            arc = p.relative_to(FYP).as_posix()
        z.write(p, arc)

print(f"WROTE {OUT}")
print(f"FILES {len(unique)}")
print(f"BYTES {OUT.stat().st_size}")
for p in unique:
    arc = "00_TRANSCRIPT_OPTIONAL/session_20261121.jsonl" if p == TRANSCRIPT else p.relative_to(FYP).as_posix()
    print(f"  {arc}")
