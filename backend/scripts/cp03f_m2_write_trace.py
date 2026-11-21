"""CP-03F: obtain the real database exception behind M2_SOURCE_UNAVAILABLE.

The HTTP route maps every ``SQLAlchemyError`` to a fixed 503 and the Jaspr panel
swallows the body with ``catch (_)``, so the actual cause is invisible from the
browser. This drives ``M2Service.update_answer`` directly with the same actor and
body the browser used and prints the full traceback.

Read-only until ``update_answer`` is called; that call is a real write, and it is
rolled back by the service on any failure. Prints the assessment revision before
and after so the effect is explicit.
"""
from __future__ import annotations

import sys
import traceback
from pathlib import Path
from uuid import UUID

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
sys.path.insert(0, str(HERE))

ASSESSMENT = UUID("510dfdd8-4bdd-4e00-915c-d5d7fa9df747")
ITEM_KEY = "M2V1-04"
VALUE = ["STUDENTS", "OFFICE_WORKERS"]


def main() -> int:
    import cp03f_e2e_browser as H  # noqa: E402
    from sitewise.db.m2_session import m2_session_for  # noqa: E402
    from sitewise.repositories.m2_repository import SqlModelM2Repository  # noqa: E402
    from sitewise.services.m2_service import M2Service  # noqa: E402

    sub_id, _email, _ = H.entrepreneur()
    actor = UUID(sub_id)

    with m2_session_for(actor) as session:
        repo = SqlModelM2Repository(session)
        service = M2Service(repo)
        try:
            before = service.read_assessment(ASSESSMENT, actor)
        except Exception:
            traceback.print_exc()
            return 3
        revision = (before.get("assessment") or {}).get("revision")
        if revision is None:
            print("cannot determine revision from response keys:", sorted(before))
            return 3
        print("actor:", actor)
        print("assessment revision before:", revision)
        print("item:", ITEM_KEY, "value:", VALUE)

        try:
            result = service.update_answer(
                ASSESSMENT, actor,
                expected_revision=int(revision),
                item_key=ITEM_KEY, state="ANSWERED", value=VALUE,
            )
            print("OK -> new revision:", result["assessment_revision"])
            print("answer:", result["answer"])
            return 0
        except Exception as exc:  # noqa: BLE001 - the whole point is to see it
            print("FAILED:", type(exc).__module__ + "." + type(exc).__name__)
            print("-" * 70)
            traceback.print_exc()
            orig = getattr(exc, "orig", None)
            if orig is not None:
                print("-" * 70)
                print("DBAPI error:", type(orig).__name__)
                for attr in ("pgcode", "pgerror", "diag"):
                    val = getattr(orig, attr, None)
                    if val is not None:
                        diag = getattr(val, "message_primary", None) if attr == "diag" else None
                        print(f"  {attr}: {diag or val}")
            return 2


if __name__ == "__main__":
    raise SystemExit(main())
