"""Diagnose which M2 answer fails validation for the synthetic assessment."""
import sys
from pathlib import Path
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sqlalchemy import create_engine, text  # noqa: E402
from sqlmodel import Session  # noqa: E402

from sitewise.core.config import settings  # noqa: E402
from sitewise.modules.decision_engine.domain.m2_rules import validate_m2_answer  # noqa: E402
from sitewise.repositories.m2_repository import SqlModelM2Repository  # noqa: E402

ACTOR = UUID("11111111-1111-4111-8111-111111111111")
ASSESSMENT = UUID("da90aa4a-f9cf-4145-9acf-7de36c9d6fad")
REV = 12

engine = create_engine(settings.m2_database_url.get_secret_value(), hide_parameters=True)
with Session(engine) as session:
    session.execute(text("SELECT set_config('project1.actor_id', :a, true)"), {"a": str(ACTOR)})
    repo = SqlModelM2Repository(session)
    a = repo.get_assessment(ASSESSMENT, ACTOR)
    print("assessment", a["id"], "rev", a["revision"], "confirmed", a.get("confirmed_revision"), "instrument", a["instrument_id"])
    inst = repo.get_instrument(a["instrument_id"])
    print("instrument", inst.get("version_tag"), "approval", inst.get("approval_state"))
    items = {i["item_key"]: i for i in repo.list_items(a["instrument_id"])}
    answers = repo.get_latest_answers(ASSESSMENT, REV)
    print("answers", len(answers), "items", len(items))
    for key, ans in sorted(answers.items()):
        item = items.get(key)
        if not item:
            print(f"  {key}: NO ITEM")
            continue
        try:
            validate_m2_answer(item, ans["answer_state"], ans["value_json"])
            status = "OK"
        except Exception as exc:  # noqa: BLE001
            status = f"FAIL {type(exc).__name__}: {exc}"
        print(f"  {key}: state={ans['answer_state']} kind={item['answer_kind']} value={str(ans['value_json'])[:50]} -> {status}")
