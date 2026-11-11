"""pytest plugin: append failure reports to a file (env kills stdout)."""

from __future__ import annotations

import pathlib

_OUT = pathlib.Path(
    "C:/Users/Lenovo/AndroidStudioProjects/FYP/.workbuddy-ai/tmp/failures.txt"
)


def pytest_runtest_logreport(report):
    if report.failed or report.outcome == "error":
        with _OUT.open("a", encoding="utf-8") as f:
            f.write(f"\n=== {report.nodeid}\n{report.longreprtext}\n")


def pytest_sessionstart(session):
    _OUT.write_text("", encoding="utf-8")
