from types import SimpleNamespace
from unittest.mock import Mock
from uuid import uuid4

import pytest
from fastapi import HTTPException

from sitewise.api.v1 import capture_360
from sitewise.core.exceptions import ConflictError
from sitewise.services import agent_inspection_policy as policy
from sitewise.services import capture_session_service as service


@pytest.fixture
def submitted(monkeypatch):
    agent = SimpleNamespace(user_id=uuid4(), role="agent")
    capture = SimpleNamespace(
        id=service.capture_session_id_for_key("original-attempt"),
        property_id="42",
        owner_id=agent.user_id,
        status="completed",
        capture_mode="device_38_panorama",
        capture_plan_version="2",
        expected_frames=38,
    )
    assignment = {"workflow_status": "submitted", "panorama_id": uuid4()}
    monkeypatch.setattr(policy, "agent_assignment", lambda *_: assignment)
    db = Mock()
    db.execute.return_value.scalar.return_value = True
    return db, capture, agent


def test_backup_is_allowed_only_for_pinned_capture(submitted):
    db, capture, agent = submitted
    assert policy.require_frame_backup(db, capture, agent) is True
    assert db.execute.call_args.args[1]["session_id"] == str(capture.id)
    db.execute.return_value.scalar.return_value = False
    with pytest.raises(HTTPException) as exc:
        policy.require_frame_backup(db, capture, agent)
    assert exc.value.status_code == 409


def test_different_agent_cannot_back_up_submitted_capture(submitted):
    db, capture, _ = submitted
    with pytest.raises(HTTPException) as exc:
        policy.require_frame_backup(db, capture, SimpleNamespace(user_id=uuid4()))
    assert exc.value.status_code == 403
    db.execute.assert_not_called()


def test_restart_resolves_submitted_attempt_without_creating_session(submitted, monkeypatch):
    db, capture, agent = submitted
    monkeypatch.setattr(capture_360, "agent_assignment", Mock(side_effect=HTTPException(409)))
    monkeypatch.setattr(service, "get_capture_session", Mock(side_effect=lambda _, key: capture if key == capture.id else None))
    monkeypatch.setattr(service, "ensure_property_access", Mock())
    monkeypatch.setattr(service, "confirmed_frame_count", Mock(return_value=37))
    create = Mock()
    monkeypatch.setattr(service, "create_capture_session", create)
    monkeypatch.setattr(capture_360, "_session_json", lambda record, count: (record.id, count))

    body = capture_360.SessionCreate(
        property_id=42, capture_mode=capture.capture_mode, idempotency_key="original-attempt"
    )
    assert capture_360.create_session(body, db, agent) == (capture.id, 37)
    with pytest.raises(HTTPException) as exc:
        capture_360.create_session(body.model_copy(update={"idempotency_key": "new-attempt"}), db, agent)
    assert exc.value.status_code == 409
    create.assert_not_called()


def test_confirmed_original_is_idempotent_and_cannot_be_replaced(submitted):
    db, capture, _ = submitted
    original = SimpleNamespace(storage_path="original.jpg", checksum_sha256="a" * 64)
    db.get.side_effect = [capture, original, capture, original]
    db.execute.return_value.first.return_value = (uuid4(),)
    fields = dict(
        session_id=capture.id, target_index=38, storage_path=original.storage_path,
        image_width=None, image_height=None, capture_pose=None, captured_at=None,
        append_only=True,
    )
    assert service.confirm_frame(db, checksum_sha256=original.checksum_sha256, **fields) == (original, False)
    with pytest.raises(ConflictError):
        service.confirm_frame(db, checksum_sha256="b" * 64, **fields)
    db.add.assert_not_called()


def test_last_original_can_upload_and_confirm_after_submission(submitted, monkeypatch):
    db, capture, agent = submitted
    storage = capture_360.capture_storage
    content = b"test original"
    path = storage.frame_object_path(capture.property_id, str(capture.id), 38)
    monkeypatch.setattr(service, "require_capture_session", Mock(return_value=capture))
    monkeypatch.setattr(
        storage, "signed_upload_url", Mock(
            return_value=SimpleNamespace(target_index=38, storage_path=path, upload_url="signed")
        )
    )
    monkeypatch.setattr(storage, "object_exists", Mock(return_value=True))
    monkeypatch.setattr(storage, "download", Mock(return_value=content))
    monkeypatch.setattr(service, "list_capture_frames", Mock(return_value=[]))
    confirmation = Mock(return_value=(object(), True))
    monkeypatch.setattr(service, "confirm_frame", confirmation)
    monkeypatch.setattr(capture_360, "_frame_json", lambda _, created: {"created": created})

    response = capture_360.issue_upload_urls(
        capture.id, capture_360.UploadUrlRequest(targets=[38]), db, agent
    )
    assert response["uploads"][0]["storagePath"] == path
    body = capture_360.FrameConfirm(
        target_index=38, storage_path=path, checksum_sha256=storage.sha256_hex(content)
    )
    assert capture_360.confirm_frame(capture.id, body, db, agent) == {"created": True}
    assert confirmation.call_args.kwargs["append_only"] is True
    with pytest.raises(ConflictError):
        capture_360.confirm_frame(
            capture.id, body.model_copy(update={"checksum_sha256": "0" * 64}), db, agent
        )
    assert confirmation.call_count == 1
