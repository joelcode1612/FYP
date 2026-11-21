"""Smoke test for the Dart→Python panorama port.

Generates 38 textured portrait frames placed on the exact sphere layout with
the assumed 65° vFOV, then runs the full server pipeline: registration,
projection, gains, seam compositing, gap fill, coverage audit, gates, JPEG.
A passing run means the port projects a complete 2:1 equirectangular from the
same records.json shape the mobile app writes.

Run:  backend/.venv/Scripts/python.exe backend/scripts/smoke_panorama_port.py
"""

from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path

import cv2
import numpy as np

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND / "src"))

from sitewise.panorama.stitcher import stitch_equirectangular  # noqa: E402
from sitewise.panorama.sphere_math import UNIT_X, UNIT_Y, Quat, Vec3  # noqa: E402

OUT = BACKEND / "var" / "panorama_smoke"
W, H = 768, 1024
VFOV = 65.0


def sphere_direction(yaw_deg: float, pitch_deg: float) -> tuple[float, float, float]:
    yaw = math.radians(yaw_deg)
    pitch = math.radians(pitch_deg)
    horizontal = math.cos(pitch)
    return (
        math.sin(yaw) * horizontal,
        math.sin(pitch),
        -math.cos(yaw) * horizontal,
    )


def pose_for(yaw_deg: float, pitch_deg: float) -> Quat:
    # Maps the camera axis (−Z) onto the sphere direction. Verified against
    # sphereDirection in the assert below.
    return Quat.axis_angle(-yaw_deg, UNIT_Y) * Quat.axis_angle(pitch_deg, UNIT_X)


def layout() -> list[tuple[int, float, float]]:
    targets: list[tuple[int, float, float]] = []
    middle = [0, 30, 60, 90, 120, 150, 180, -150, -120, -90, -60, -30]
    upper = [-30, -60, -90, -120, -150, 180, 150, 120, 90, 60, 30, 0]
    lower = middle[:]
    target_id = 0
    for yaw in middle:
        target_id += 1
        targets.append((target_id, yaw, 0.0))
    target_id += 1
    targets.append((target_id, 0.0, 90.0))
    for yaw in upper:
        target_id += 1
        targets.append((target_id, yaw, 35.0))
    for yaw in lower:
        target_id += 1
        targets.append((target_id, yaw, -35.0))
    target_id += 1
    targets.append((target_id, 0.0, -90.0))
    return targets


def make_frame(path: Path, target_id: int) -> None:
    rng = random.Random(1000 + target_id)
    hue = (target_id * 137.508) % 360.0
    base = np.full((H, W, 3), 0.45, dtype=np.float32)
    base[:, :, 0] = hue  # hsv hue channel
    base[:, :, 2] = 0.85
    img = cv2.cvtColor(base, cv2.COLOR_HSV2BGR)
    img = (img * 255).astype(np.uint8)
    for _ in range(W * H // 120):
        x, y = rng.randrange(W), rng.randrange(H)
        v = rng.randrange(0, 255)
        img[y, x] = (v, v, v)
    for _ in range(90):
        x, y = rng.randrange(W - 60), rng.randrange(H - 60)
        w, h = rng.randint(12, 60), rng.randint(12, 60)
        shade = rng.randint(0, 255)
        if rng.random() < 0.5:
            cv2.ellipse(img, (x + w // 2, y + h // 2), (w // 2, h // 2), 0, 0, 360, (shade,) * 3, 2)
        else:
            cv2.rectangle(img, (x, y), (x + w, y + h), (shade,) * 3, 2)
    cv2.putText(img, f"T{target_id:02d}", (24, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.6, (255, 255, 255), 3)
    cv2.imwrite(str(path), img, [cv2.IMWRITE_JPEG_QUALITY, 78])


def build_records() -> list[dict]:
    frame_dir = OUT / "frames"
    frame_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for target_id, yaw, pitch in layout():
        path = frame_dir / f"target_{target_id:02d}.jpg"
        if not path.exists():
            make_frame(path, target_id)
        q = pose_for(yaw, pitch)
        records.append(
            {
                "targetId": target_id,
                "imagePath": str(path),
                "cameraOrientation": [q.x, q.y, q.z, q.w],
                "imageWidth": W,
                "imageHeight": H,
                "sourceImageWidth": W,
                "sourceHeight": H,
                "cropOffsetX": 0,
                "cropOffsetY": 0,
            }
        )
    return records


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    records = build_records()

    # Pose sanity: the camera axis must land on the layout direction.
    for target_id, yaw, pitch in ((1, 0.0, 0.0), (13, 0.0, 90.0), (14, -30.0, 35.0), (25, 0.0, 35.0), (38, 0.0, -90.0)):
        q = pose_for(yaw, pitch)
        axis = q.rotate(Vec3(0.0, 0.0, -1.0))
        expected = sphere_direction(yaw, pitch)
        err = max(abs(axis.x - expected[0]), abs(axis.y - expected[1]), abs(axis.z - expected[2]))
        assert err < 1e-9, f"pose {target_id} off by {err}"

    for refine in (False, True):
        run_dir = OUT / ("unrefined" if not refine else "refined")
        run_dir.mkdir(parents=True, exist_ok=True)
        print(f"--- stitch run refine_registration={refine} ---")
        outcome = stitch_equirectangular(
            records=records,
            out_dir=run_dir,
            width=1024,
            refine_registration=refine,
            vertical_fov_deg=VFOV,
            progress=lambda m: None,
        )
        print("ok:", outcome.ok)
        print("message:", outcome.message)
        if not outcome.ok:
            return 1
        pano = cv2.imread(str(run_dir / "panorama.jpg"))
        assert pano is not None, "panorama.jpg missing"
        assert pano.shape[0] == 512 and pano.shape[1] == 1024, f"bad size {pano.shape}"
        report = json.loads((run_dir / "coverage_report.json").read_text())
        assert (run_dir / "coverage_map.jpg").exists()
        assert report["passed"] is True, f"coverage failed: {report['coveragePercent']}"
        assert report["coveragePercent"]["single"] >= 99.5
        assert report["panorama"]["width"] == 1024 and report["panorama"]["height"] == 512
        assert len(report["colourGains"]) == 38
        for key in (
            "seamPixels",
            "seamPixelsMoved",
            "overlapPixels",
            "ghostEnergy",
            "ghostFraction",
            "multiBand",
            "seamDiscontinuity",
            "wrapDiscontinuity",
            "graphCut",
        ):
            assert key in report["seamBlend"], f"missing seamBlend key {key}"
        assert report["worstViewportGapPercent"] <= 25.0
        assert report["photographCount"] == 38
        assert "registration" in report and "timingsMs" in report
        print(
            "coverage single={single:.2f}% double={double:.2f}% gap={gap:.2f}% "
            "filled={filled} seam={seam}".format(
                single=report["coveragePercent"]["single"],
                double=report["coveragePercent"]["double"],
                gap=report["worstViewportGapPercent"],
                filled=report["gapFilledPixels"],
                seam=report["seamBlend"]["seamDiscontinuity"],
            )
        )
        print(
            "registration: pairs={p} accepted={a} rejected={r} maxCorr={m:.3f}".format(
                p=report["registration"]["pairsConsidered"],
                a=report["registration"]["acceptedEdges"],
                r=report["registration"]["rejectedEdges"],
                m=report["registration"]["maxCorrectionDeg"],
            )
        )
        print("timings:", report["timingsMs"])
    print("SMOKE PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
