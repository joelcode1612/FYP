"""Live smoke test for the capture storage gateway (real Supabase project).

Proves the whole signed-direct-upload transport: private bucket creation,
short-lived upload URL issuance, an actual PUT from an uncredentialed client
(the exact request the Flutter app will make), existence verification,
checksum integrity, a signed view URL, and cleanup.

Run:  backend/.venv/Scripts/python.exe backend/scripts/smoke_capture_storage.py
"""

from __future__ import annotations

import hashlib
import sys
from datetime import UTC, datetime
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from dotenv import load_dotenv

load_dotenv(BACKEND / ".env")

import cv2
import numpy as np

from sitewise.services import capture_storage as cs

FAKE_PROPERTY = 9236


def main() -> int:
    session_id = f"smoke-storage-{datetime.now(UTC).strftime('%Y%m%d%H%M%S')}"
    path = cs.frame_object_path(FAKE_PROPERTY, session_id, 1)
    print("object:", path)

    # 1. Private bucket exists.
    cs.ensure_bucket()
    print("  ok: bucket ensured (private)")

    # 2. A tiny JPEG fixture, encoded once.
    img = np.zeros((64, 64, 3), dtype=np.uint8)
    img[:, :, 2] = 200
    ok, buf = cv2.imencode(".jpg", img)
    assert ok
    data = buf.tobytes()
    digest = hashlib.sha256(data).hexdigest()

    # 3. Signed upload URL + real PUT with the same headers Flutter sends.
    signed = cs.signed_upload_url(storage_path=path, target_index=1)
    assert "token=" in signed.upload_url
    import urllib.request
    import urllib.error

    def put(url: str) -> int:
        req = urllib.request.Request(
            url,
            data=data,
            method="PUT",
            headers={"content-type": "image/jpeg"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.status
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            if exc.code == 400 and "KeyAlreadyExists" in body:
                return 409  # duplicate = the bytes are already stored
            raise

    status = put(signed.upload_url)
    assert status in (200, 201), f"PUT failed with {status}"
    print("  ok: uncredentialed PUT through signed URL ->", status)

    # 4. Retry idempotence: the same PUT again -> 409 Duplicate = stored.
    status = put(signed.upload_url)
    assert status == 409
    print("  ok: re-upload answered 409 Duplicate (= already stored)")

    # 5. Existence + integrity.
    assert cs.object_exists(path)
    downloaded = cs.download(path)
    assert cs.verify_checksum(downloaded, digest)
    assert not cs.verify_checksum(downloaded, "0" * 64)
    print("  ok: object exists, sha256 verified, mismatch detected")

    # 6. Signed view URL.
    view = cs.signed_view_url(path, expires_in=120)
    with urllib.request.urlopen(view, timeout=30) as response:
        assert response.status == 200 and response.read() == data
    print("  ok: signed view URL serves the exact bytes")

    # 7. Missing object behaves.
    try:
        cs.download(path.rsplit("/", 1)[0] + "/absent.jpg")
        raise AssertionError("ObjectMissing not raised")
    except cs.ObjectMissing:
        print("  ok: missing object -> ObjectMissing")

    # 8. Cleanup.
    removed = cs.remove_prefix(f"properties/{FAKE_PROPERTY}/sessions/{session_id}")
    assert not cs.object_exists(path)
    print(f"  ok: cleanup removed {removed} object(s)")
    print("STORAGE SMOKE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
