"""Verify package completeness and create the deliverable ZIP without secrets."""
from __future__ import annotations

import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIP_PATH = ROOT.with_suffix(".zip")

REQUIRED = [
    "expanded64_v2_recalculated_features.csv",
    "expanded64_v2_feature_comparison.csv",
    "expanded64_v2_subject_comparison.csv",
    "expanded64_v2_missing_features.csv",
    "expanded64_v2_source_inventory.json",
    "expanded64_v2_extraction_summary.json",
    "expanded64_v2_remaining58_validation.csv",
    "expanded64_v2_runtime_feature_handoff.md",
    "original_training_data/SiteWise_PU_1796_Expanded_Observed.csv",
    "source/extract_expanded64_v2.py",
    "source/validate_sources.py",
    "source/export_and_compare.py",
    "source/validate_remaining58.py",
    "sql/01_source_inventory.sql",
    "sql/02_extraction_queries.sql",
    "sql/03_calculator_sql_verbatim.sql",
    "logs/extraction.log",
    "logs/source_inventory.log",
    "requirements.txt",
    "README.md",
]

SECRET_PATTERNS = (
    re.compile(r"DATABASE_URL\s*=\s*postgresql[^<>\n]*://[^<>\n:]+:[^<>\n@]+@"),
    re.compile(r"password\s*[=:]\s*\S+", re.I),
)
# The caller-supplied numeric password is checked only in human-authored
# files; numeric CSV/JSONL measurements can legitimately contain that digit run.
PASSWORD_DIGITS = re.compile(r"(?<![\d.])" + "12" + "3456" + r"(?![\d.])")
DATA_SUFFIXES = {".csv", ".jsonl"}


def main() -> None:
    missing = [name for name in REQUIRED if not (ROOT / name).is_file()]
    if missing:
        raise RuntimeError(f"Missing required files: {missing}")

    text_files = [
        p for p in ROOT.rglob("*")
        if p.is_file() and p.suffix.lower() in {".py", ".md", ".txt", ".sql", ".json", ".csv", ".log", ".jsonl"}
    ]
    leaks = []
    for path in text_files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(text):
                leaks.append(f"{path.relative_to(ROOT)}:{pattern.pattern}")
        if path.suffix.lower() not in DATA_SUFFIXES and PASSWORD_DIGITS.search(text):
            leaks.append(f"{path.relative_to(ROOT)}:numeric password token")
    if leaks:
        raise RuntimeError(f"Potential credential material in package: {leaks[:20]}")

    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(ROOT.rglob("*")):
            if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            zf.write(path, path.relative_to(ROOT.parent))
    print(f"Wrote {ZIP_PATH} ({ZIP_PATH.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
