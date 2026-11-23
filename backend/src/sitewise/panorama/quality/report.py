"""Finding and report models shared by every quality verifier.

A report is plain-JSON-serialisable (it is stored inside the panorama row's
``coverage_report`` column) and every message is written to be shown to the
agent verbatim. Findings distinguish severity the same way the device side
does: ``warning`` is advisory evidence, ``error`` marks genuinely broken
input, ``info`` records measurements that must never alarm anyone.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

SEVERITY_INFO = "info"
SEVERITY_WARNING = "warning"
SEVERITY_ERROR = "error"

VERDICT_PASS = "pass"
VERDICT_WARNING = "warning"


@dataclass(slots=True)
class QualityFinding:
    """One measured result of one check, with its evidence numbers."""

    check: str
    severity: str
    code: str
    message: str
    evidence: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "check": self.check,
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "evidence": self.evidence,
        }

    @classmethod
    def info(
        cls, check: str, code: str, message: str, **evidence: Any
    ) -> "QualityFinding":
        return cls(
            check=check,
            severity=SEVERITY_INFO,
            code=code,
            message=message,
            evidence=evidence,
        )

    @classmethod
    def warning(
        cls, check: str, code: str, message: str, **evidence: Any
    ) -> "QualityFinding":
        return cls(
            check=check,
            severity=SEVERITY_WARNING,
            code=code,
            message=message,
            evidence=evidence,
        )

    @classmethod
    def error(
        cls, check: str, code: str, message: str, **evidence: Any
    ) -> "QualityFinding":
        return cls(
            check=check,
            severity=SEVERITY_ERROR,
            code=code,
            message=message,
            evidence=evidence,
        )


@dataclass(slots=True)
class QualityReport:
    """All findings of one verification pass, plus the aggregated verdict."""

    check: str
    findings: list[QualityFinding] = field(default_factory=list)
    measurements: dict[str, Any] = field(default_factory=dict)

    def add(self, finding: QualityFinding) -> None:
        self.findings.append(finding)

    @property
    def warning_count(self) -> int:
        return sum(1 for f in self.findings if f.severity == SEVERITY_WARNING)

    @property
    def error_count(self) -> int:
        return sum(1 for f in self.findings if f.severity == SEVERITY_ERROR)

    @property
    def verdict(self) -> str:
        """``pass`` unless at least one WARNING/ERROR finding exists.

        Verification never blocks the pipeline — the verdict is the honest
        one-line answer to "is there anything an agent or a reviewer should
        look at".
        """
        if self.warning_count or self.error_count:
            return VERDICT_WARNING
        return VERDICT_PASS

    def to_dict(self) -> dict[str, Any]:
        return {
            "check": self.check,
            "verdict": self.verdict,
            "warning_count": self.warning_count,
            "error_count": self.error_count,
            "measurements": self.measurements,
            "findings": [f.to_dict() for f in self.findings],
        }
