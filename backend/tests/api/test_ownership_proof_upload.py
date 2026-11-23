"""Exercise the real upload route inside a rolled-back PostgreSQL transaction."""
from types import SimpleNamespace
from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlmodel import Session

from sitewise.api.v1.property_verification import submitter_router
from sitewise.core.config import settings
from sitewise.db.session import engine, get_db
from sitewise.dependencies import require_property_owner
from sitewise.repositories.user_repository import UserRepository
from .test_property_verification_api import insert_listing


def test_proof_upload_preserves_accepted_inspection(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "verification_storage_dir", str(tmp_path))
    owner = SimpleNamespace(role="owner", user_id=uuid4())
    app = FastAPI()
    app.include_router(submitter_router, prefix="/api/v1/properties")
    with engine.connect() as connection, connection.begin() as outer:
        with Session(connection, join_transaction_mode="create_savepoint") as session:
            UserRepository(session).get_or_create_from_supabase(
                user_id=owner.user_id, email=f"{owner.user_id}@example.invalid", email_verified=True
            )
            pid = insert_listing(session, str(owner.user_id), name="Upload fixture",
                                 address="Test street", city="Test city", state="Test state")
            assert pid != 11904
            session.execute(text("""
                INSERT INTO fyp.agent_listing_assignment
                    (listing_id, agent_id, workflow_status, inspection_data, panorama_id)
                VALUES (:pid, 1, 'accepted', '{"floor_area_verified": true}', :tour)
            """), {"pid": pid, "tour": str(uuid4())})
            query = text("SELECT * FROM fyp.agent_listing_assignment WHERE listing_id=:pid")
            before = session.execute(query, {"pid": pid}).one()
            app.dependency_overrides[get_db] = lambda: session
            app.dependency_overrides[require_property_owner] = lambda: owner
            with TestClient(app) as client:
                def upload(ext, mime, data):
                    return client.post(f"/api/v1/properties/{pid}/verification/documents",
                        data={"verification_type":"ownership", "document_type":"ownership_proof"},
                        files={"file": (f"proof.{ext}", data, mime)})

                owner.role = "agent"
                assert upload("pdf", "application/pdf", b"%PDF-1.4").status_code == 403
                owner.role = "owner"
                for ext, mime, data in [
                    ("pdf", "application/octet-stream", b"%PDF-1.4"),
                    ("jpg", "image/jpeg", b"%PDF-1.4"),
                    ("exe", "application/pdf", b"%PDF-1.4"),
                ]:
                    assert upload(ext, mime, data).status_code == 422
                for ext, mime, data in [
                    ("pdf", "application/pdf", b"%PDF-1.4"),
                    ("jpg", "image/jpeg", b"\xff\xd8\xff\xe0"),
                    ("jpeg", "image/jpeg", b"\xff\xd8\xff\xe1"),
                    ("png", "image/png", b"\x89PNG\r\n\x1a\n"),
                    ("webp", "image/webp", b"RIFF1234WEBPVP8L"),
                ]:
                    response = upload(ext, mime, data)
                    assert response.status_code == 201, response.text
                    doc = response.json()
                    assert (doc["property_id"], doc["mime_type"], doc["file_size"], doc["status"]) == (
                        pid, mime, len(data), "active")
                    key = session.execute(text("SELECT storage_key FROM fyp.verification_document "
                        "WHERE document_id=:id"), {"id":doc["document_id"]}).scalar_one()
                    assert (tmp_path / key).read_bytes() == data
            assert session.execute(query, {"pid":pid}).one() == before
            for table, expected in [("property_verification", 1), ("verification_document", 5),
                                    ("verification_audit", 5)]:
                assert session.execute(text(f"SELECT count(*) FROM fyp.{table} WHERE property_id=:pid"),
                                       {"pid":pid}).scalar_one() == expected
        outer.rollback()
