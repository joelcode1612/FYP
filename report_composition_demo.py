
# report_composition_demo.py
# PROJECT1 — SYNTHETIC TEST ONLY
# Not an adopted A10 implementation or production report engine.

import copy
import hashlib
import json
from pathlib import Path

HEADINGS = {
    "R01": "Business concept and declared plan",
    "R02": "Survey recruitment, eligibility and consent",
    "R03": "Stated interest in visiting",
    "R04": "Interested product categories",
    "R05": "Price acceptability for an exact offer",
    "R06": "Existing-café purchasing behavior",
    "R07": "Occasions and experience priorities",
    "R08": "Study-area affiliation and limited geographic context",
    "R09": "Dated external business and competitor context",
    "R10": "Financial and operational planning assumptions",
    "R11": "Overall suitability conclusion — availability only",
    "R12": "Methods, source limitations and outstanding evidence",
}

# This is a SYNTHETIC test mapping, NOT the actual A10 register.
TEST_MAPPING = {
    "R01": {"m2"},
    "R03": {"measurement"},
    "R05": {"measurement"},
    "R09": {"external", "rental"},
    "R10": {"rental"},
    "R12": {"method"},
}


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def source(source_id, version, content):
    return {
        "source_id": source_id,
        "version": version,
        "content": content,
        "sha256": digest(content),
        "synthetic": True,
    }


SOURCES = {
    "M2-04-R1": source(
        "M2-04-R1", "1",
        "The entrepreneur plans a fictional hybrid café "
        "offering coffee, pastries and light meals."
    ),
    "CQ-Q05-S1": source(
        "CQ-Q05-S1", "1",
        "Synthetic Q05-v1: num=30;den=55; "
        "concept=fictional-hybrid-cafe-v1."
    ),
    "CQ-Q07-S1": source(
        "CQ-Q07-S1", "1",
        "Synthetic Q07-v1: num=48;den=80; "
        "offer=300ml-coffee-RM12-v1."
    ),
    "EXT-S1": source(
        "EXT-S1", "1",
        "A fictional October 2026 competitor register "
        "contains two illustrative cafés. "
        "It is not a real market survey."
    ),
    "RENT-A": source(
        "RENT-A", "1",
        "Synthetic Property A quotation: RM4500/month."
    ),
    "RENT-B": source(
        "RENT-B", "1",
        "Synthetic Property B quotation: RM5200/month."
    ),
    "METHOD-S1": source(
        "METHOD-S1", "1",
        "This demonstration uses synthetic inputs only. "
        "No real respondent fieldwork or source review occurred."
    ),
}

FINDINGS = [
    {
        "id": "F-R01",
        "section": "R01",
        "type": "m2",
        "source": "M2-04-R1",
        "support": "SUPPORTED",
        "text": SOURCES["M2-04-R1"]["content"],
        "limit": "Entrepreneur declaration, not verified demand.",
    },
    {
        "id": "F-R03",
        "section": "R03",
        "type": "measurement",
        "source": "CQ-Q05-S1",
        "support": "SUPPORTED",
        "numerator": 30,
        "denominator": 55,
        "description": "selected an interested response category",
        "limit": "Stated interest is not an actual visit.",
    },
    {
        "id": "F-R05",
        "section": "R05",
        "type": "measurement",
        "source": "CQ-Q07-S1",
        "support": "SUPPORTED",
        "numerator": 48,
        "denominator": 80,
        "description": "selected acceptable for the fictional RM12 offer",
        "limit": "Price acceptability is not actual purchasing.",
    },
    {
        "id": "F-R09",
        "section": "R09",
        "type": "external",
        "source": "EXT-S1",
        "support": "SUPPORTED",
        "text": SOURCES["EXT-S1"]["content"],
        "limit": "Fictional register; no real competitor claim.",
    },
    {
        "id": "F-RENT-A",
        "section": "R09",
        "type": "rental",
        "source": "RENT-A",
        "support": "SUPPORTED",
        "text": SOURCES["RENT-A"]["content"],
        "limit": "Not a recommendation to lease.",
    },
    {
        "id": "F-RENT-B",
        "section": "R09",
        "type": "rental",
        "source": "RENT-B",
        "support": "SUPPORTED",
        "text": SOURCES["RENT-B"]["content"],
        "limit": "Not a recommendation to lease.",
    },
    {
        "id": "F-METHOD",
        "section": "R12",
        "type": "method",
        "source": "METHOD-S1",
        "support": "SUPPORTED",
        "text": SOURCES["METHOD-S1"]["content"],
        "limit": "No scientific or publication authorization.",
    },
]


def validate_finding(finding, sources):
    # The four EE-01 fact-support outcomes remain unchanged.
    # SUPPORTED here is an authored SYNTHETIC oracle,
    # not an actual scientific review.

    src = sources.get(finding["source"])
    if src is None:
        return None, "SOURCE_NOT_FOUND"

    if not src["synthetic"]:
        return None, "NON_SYNTHETIC_SOURCE_REFUSED"

    if digest(src["content"]) != src["sha256"]:
        return None, "SOURCE_DIGEST_MISMATCH"

    if finding["support"] != "SUPPORTED":
        return None, f"SOURCE_{finding['support']}"

    allowed_types = TEST_MAPPING.get(finding["section"], set())
    if finding["type"] not in allowed_types:
        return None, "SYNTHETIC_MAPPING_NOT_ALLOWED"

    if finding["type"] == "measurement":
        n = finding["numerator"]
        d = finding["denominator"]

        if (not isinstance(n, int) or isinstance(n, bool)
                or not isinstance(d, int) or isinstance(d, bool)
                or d <= 0 or n < 0 or n > d):
            return None, "INVALID_NUMERATOR_DENOMINATOR"

        # Synthetic source-value consistency check.
        marker = f"num={n};den={d}"
        if marker not in src["content"]:
            return None, "MEASUREMENT_SOURCE_MISMATCH"

        percentage = n / d * 100
        text = (
            f"Among {d} synthetic valid responses, "
            f"{n} ({percentage:.1f}%) "
            f"{finding['description']}."
        )
    else:
        text = finding["text"]

        # Exact source-text equality for this narrow demonstration.
        # It does NOT establish truth in the real world.
        if text != src["content"]:
            return None, "CLAIM_SOURCE_TEXT_MISMATCH"

    return {
        "claim_id": finding["id"],
        "text": text,
        "limitation": finding["limit"],
        "source_id": src["source_id"],
        "source_version": src["version"],
        "source_sha256": src["sha256"],
        "support": finding["support"],
        "admission": "SYNTHETIC_PREVIEW_ONLY",
        "llm_attempt_id": None,
    }, None


def compose_report(findings, sources):
    sections = {}
    rejections = []

    for code, title in HEADINGS.items():
        sections[code] = {
            "heading": title,
            "claims": [],
            "notice": "No authorized synthetic fixture supplied.",
        }

    for finding in findings:
        claim, error = validate_finding(finding, sources)

        if error:
            rejections.append({
                "claim_id": finding["id"],
                "reason": error,
            })
            continue

        section = sections[finding["section"]]
        section["claims"].append(claim)
        section["notice"] = None

    # Report publication is intentionally impossible here.
    report = {
        "assessment_id": "A-DEMO-001",
        "fixture": "SYNTHETIC_ONLY",
        "report_status": "PREVIEW_NOT_ADMITTED",
        "production_release_allowed": False,
        "llm_required": False,
        "sections": sections,
        "rejections": rejections,
    }

    payload = json.dumps(report, sort_keys=True)
    report["snapshot_sha256"] = digest(payload)
    return report


def markdown_report(report):
    lines = [
        "# Project1 — Synthetic Demand Suitability Report",
        "",
        "**SYNTHETIC PREVIEW — NOT ADMITTED**",
        "",
    ]

    for code, section in report["sections"].items():
        lines.append(f"## {code} — {section['heading']}")
        lines.append("")

        if not section["claims"]:
            lines.append(
                section["notice"]
                + " This does not mean zero demand."
            )
        else:
            for claim in section["claims"]:
                lines.append(claim["text"])
                lines.append("")
                lines.append(
                    f"**Limit:** {claim['limitation']}"
                )
                lines.append(
                    "**Source:** "
                    f"{claim['source_id']} "
                    f"v{claim['source_version']} "
                    f"| SHA-256 {claim['source_sha256'][:12]}..."
                )
                lines.append(
                    f"**Claim:** {claim['claim_id']} "
                    "| Synthetic preview only"
                )
                lines.append("")

    return "\n".join(lines)


def run_tests():
    report = compose_report(FINDINGS, SOURCES)

    # All original report headings remain present.
    assert list(report["sections"]) == list(HEADINGS)
    assert len(report["sections"]) == 12

    # Both expected numerical results derive from the fixtures.
    assert "54.5%" in markdown_report(report)
    assert "60.0%" in markdown_report(report)

    # Missing section evidence is explicitly unavailable.
    assert report["sections"]["R04"]["claims"] == []

    # Source tampering must invalidate the affected claim.
    tampered = copy.deepcopy(SOURCES)
    tampered["CQ-Q05-S1"]["content"] = "tampered"
    rejected = compose_report(FINDINGS, tampered)
    assert any(
        x["reason"] == "SOURCE_DIGEST_MISMATCH"
        for x in rejected["rejections"]
    )

    # Unsupported fact claims are not rendered.
    unsupported = copy.deepcopy(FINDINGS)
    unsupported[0]["support"] = "INSUFFICIENT"
    rejected = compose_report(unsupported, SOURCES)
    assert rejected["sections"]["R01"]["claims"] == []

    # The synthetic engine can never publish.
    assert report["production_release_allowed"] is False
    assert report["report_status"] == "PREVIEW_NOT_ADMITTED"

    return report


if __name__ == "__main__":
    result = run_tests()
    Path("synthetic_report.json").write_text(
        json.dumps(result, indent=2),
        encoding="utf-8",
    )
    Path("synthetic_report.md").write_text(
        markdown_report(result),
        encoding="utf-8",
    )
    print("Synthetic smoke assertions passed.")
    print("Created synthetic_report.json and synthetic_report.md")
