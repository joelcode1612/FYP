"""Server-side equirectangular stitching for the 38-target sphere flow.

Faithful port of ``lib/features/sphere_capture/data/equirectangular_stitcher.dart``.

Every frame is projected onto a 2:1 equirectangular canvas through its
recorded (and ORB-refined) orientation, one photograph owns each pixel across
a graph-cut seam, per-frame per-channel gains match exposure, uncovered
directions are gap-filled and reported, and the 99.5% coverage gate plus the
90°-viewport gate decide whether a panorama is written at all. A failing
station never loses its photographs and never produces a panorama file.

The projection is vectorised per frame with numpy but reproduces the Dart
per-pixel semantics exactly: strict ``>`` merge order, half-away-from-zero
rounding, Float32 weight storage, RGB byte order in the accumulator.
"""

from __future__ import annotations

import json
import math
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

from .equirect_bounds import equirect_frame_bounds
from .frame_registration import (
    SphereRegistrationFrame,
    SphereRegistrationOutcome,
    SphereResidualAffine,
    max_correction_deg,
    register_sphere_frames,
)
from .seam_blend import SEAM_FEATHER_PX, composite_seams
from .sphere_intrinsics import decoded_projection
from .sphere_math import Quat

MIN_PIXEL_WEIGHT = 1e-4
STANDARD_WIDTH = 2048
HIGH_WIDTH = 4096
ACCUMULATOR_BUDGET_BYTES = 176 * 1024 * 1024
COVERAGE_THRESHOLD = 0.995
VIEWPORT_GAP_THRESHOLD = 0.25

_STITCHER_SHORT_SIDE_PX = 720
_STITCHER_BAND_FEATHER_PX = 40.0

_TWO_PI = 6.283185307179586
_HALF_PI = 1.5707963267948966


def sphere_stitch_accumulator_bytes(width: int) -> int:
    return width * (width // 2) * 19


def resolve_stitch_width(requested: int) -> int:
    if requested <= STANDARD_WIDTH:
        return requested
    if sphere_stitch_accumulator_bytes(HIGH_WIDTH) <= ACCUMULATOR_BUDGET_BYTES:
        return HIGH_WIDTH
    return STANDARD_WIDTH


def _dart_round(value) -> np.ndarray:
    """Dart ``double.round()``: half away from zero. Values here are >= 0."""
    return np.floor(value + 0.5)


def _smooth_step(values):
    t = np.clip(values, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _pow6(values):
    v = np.clip(values, 0.0, 1.0)
    v2 = v * v
    return v2 * v2 * v2


@dataclass(frozen=True, slots=True)
class FrameRecord:
    target_id: int
    image_path: str
    camera_orientation: tuple[float, float, float, float]
    saved_width: int
    saved_height: int
    source_width: int
    source_height: int
    crop_offset_x: int
    crop_offset_y: int

    @staticmethod
    def from_dict(raw: dict) -> "FrameRecord":
        orientation = raw.get("cameraOrientation") or [0.0, 0.0, 0.0, 1.0]
        return FrameRecord(
            target_id=int(raw.get("targetId") or 0),
            image_path=str(raw.get("imagePath") or ""),
            camera_orientation=(
                float(orientation[0]),
                float(orientation[1]),
                float(orientation[2]),
                float(orientation[3]),
            ),
            saved_width=int(raw.get("imageWidth") or 0),
            saved_height=int(raw.get("imageHeight") or 0),
            source_width=int(raw.get("sourceImageWidth") or 0),
            source_height=int(raw.get("sourceImageHeight") or 0),
            crop_offset_x=int(raw.get("cropOffsetX") or 0),
            crop_offset_y=int(raw.get("cropOffsetY") or 0),
        )


@dataclass
class StitchOutcome:
    ok: bool
    message: str
    report: dict | None = None
    panorama_path: str | None = None
    coverage_map_path: str | None = None
    coverage_single: float = 0.0
    coverage_double: float = 0.0
    coverage_triple: float = 0.0
    worst_viewport_gap: float = 0.0
    gap_filled_pixels: int = 0
    elapsed_ms: int = 0


def stitch_equirectangular(
    *,
    records: list[dict],
    out_dir: str | Path,
    width: int = STANDARD_WIDTH,
    refine_registration: bool = True,
    vertical_fov_deg: float = 65.0,
    strict_photo_coverage: bool = False,
    enable_cv_stitcher: bool = False,
    progress=None,
) -> StitchOutcome:
    """Stitches the station's photographs into ``out_dir/panorama.jpg``.

    ``records`` is the capture manifest — one map per photograph with
    ``targetId``, ``imagePath``, ``cameraOrientation`` [x, y, z, w] and the
    dimension/crop fields, exactly the JSON the mobile app already writes.
    """
    started = time.monotonic()

    def stage(message: str) -> None:
        if progress is not None:
            progress(message)

    if not records:
        return StitchOutcome(ok=False, message="The capture records are empty.")

    out_dir = Path(out_dir)
    sorted_records = sorted(records, key=lambda r: int(r.get("targetId") or 0))
    out_path = out_dir / "panorama.jpg"
    resolved_width = resolve_stitch_width(width)
    height = resolved_width // 2

    registration_frames = [
        SphereRegistrationFrame(
            target_id=record.target_id,
            image_path=record.image_path,
            rotation=_quat_from_record(record),
            saved_width=record.saved_width,
            saved_height=record.saved_height,
            source_width=record.source_width,
            source_height=record.source_height,
            crop_offset_x=record.crop_offset_x,
            crop_offset_y=record.crop_offset_y,
        )
        for record in (FrameRecord.from_dict(r) for r in sorted_records)
    ]

    stage(f"Preparing {len(sorted_records)} photographs…")
    if refine_registration:
        stage(
            f"Refining {len(sorted_records)} camera orientations against their overlaps…"
        )
        registration = register_sphere_frames(
            frames=registration_frames,
            vertical_fov_deg=vertical_fov_deg,
            on_stage=stage,
        )
    else:
        registration = SphereRegistrationOutcome.unrefined(
            registration_frames, note="Registration was switched off for this run."
        )
    rotations = registration.rotations
    registration_ms = registration.elapsed_ms
    anchor = rotations[0]

    if enable_cv_stitcher:
        stage("Matching 36 ring frames with OpenCV (optional experiment)…")
    stitcher_started = time.monotonic()
    if enable_cv_stitcher:
        band_pano, band_status = _stitch_ring_with_opencv(sorted_records, stage)
    else:
        band_pano, band_status = None, "disabled-by-default"
    stitcher_ms = int((time.monotonic() - stitcher_started) * 1000)

    stage_mark = time.monotonic()

    def lap_ms() -> int:
        nonlocal stage_mark
        now = time.monotonic()
        delta = int((now - stage_mark) * 1000)
        stage_mark = now
        return delta

    # ── Accumulators ─────────────────────────────────────────────────────
    pixel_count = resolved_width * height
    best_weight = np.zeros(pixel_count, dtype=np.float32)
    best_colour = np.zeros(pixel_count * 3, dtype=np.uint8)
    second_weight = np.zeros(pixel_count, dtype=np.float32)
    second_colour = np.zeros(pixel_count * 3, dtype=np.uint8)
    best_frame = np.full(pixel_count, -1, dtype=np.int16)
    second_frame = np.full(pixel_count, -1, dtype=np.int16)
    hits = np.zeros(pixel_count, dtype=np.uint8)

    lon_table = -math.pi + (np.arange(resolved_width) + 0.5) / resolved_width * _TWO_PI
    sin_lon = np.sin(lon_table)
    cos_lon = np.cos(lon_table)
    lat_table = _HALF_PI - (np.arange(height) + 0.5) / height * math.pi
    sin_lat = np.sin(lat_table)
    cos_lat = np.cos(lat_table)

    frame_records = [FrameRecord.from_dict(r) for r in sorted_records]
    # Target IDs 13/38 are the zenith/nadir only in the standard v1/v2
    # capture plan. Version 3 has 56 targets, with poles at 19/56. Use the
    # complete manifest to identify the plan so lower-ring target 38 is never
    # treated as the nadir photograph in an enhanced session.
    target_ids = {record.target_id for record in frame_records}
    is_enhanced_plan = target_ids == set(range(1, 57))
    pole_target_ids = {19, 56} if is_enhanced_plan else {13, 38}
    nadir_target_id = None if is_enhanced_plan else 38
    for frame_index, record in enumerate(frame_records):
        path = record.image_path
        if not path or not Path(path).exists():
            return StitchOutcome(
                ok=False, message=f"A captured photograph is missing: {path}"
            )
        decode_flag = cv2.IMREAD_REDUCED_COLOR_2 if resolved_width <= 2048 else cv2.IMREAD_COLOR
        image = cv2.imread(path, decode_flag)
        if image is None or image.size == 0:
            return StitchOutcome(
                ok=False, message=f"A photograph could not be decoded: {path}"
            )
        image_height, image_width = image.shape[:2]
        decoded = _decoded_projection_for(record, image_width, image_height, vertical_fov_deg)
        if decoded is None:
            return StitchOutcome(
                ok=False,
                message=(
                    f"A photograph has invalid dimensions ({image_width}×"
                    f"{image_height}), so it cannot be projected."
                ),
            )
        focal = decoded.focal_px
        cx = decoded.cx
        cy = decoded.cy

        camera_to_sphere = (anchor.conjugate * rotations[frame_index]).normalized
        sphere_to_camera = camera_to_sphere.conjugate

        residual = (
            registration.residual_affines[frame_index]
            if frame_index < len(registration.residual_affines)
            else SphereResidualAffine.IDENTITY
        )

        target_id = record.target_id
        is_pole = target_id in pole_target_ids
        is_nadir = target_id == nadir_target_id
        margin_x = (0.16 if is_pole else 0.05) * image_width
        margin_y = (0.16 if is_pole else 0.05) * image_height

        bounds = equirect_frame_bounds(
            camera_to_sphere, image_width, image_height, focal, cx, cy
        )
        y_start = _clamp_int(
            int(((-bounds.max_lat + _HALF_PI) / math.pi * height)) - 2, 0, height - 1
        )
        y_end = _clamp_int(
            int(math.ceil(((_HALF_PI - bounds.min_lat) / math.pi * height))) + 2,
            0,
            height - 1,
        )
        if bounds.full_width:
            x_start, x_end = 0, resolved_width - 1
        else:
            x_start = int(math.floor((bounds.min_lon + math.pi) / _TWO_PI * resolved_width)) - 2
            x_end = int(math.ceil((bounds.max_lon + math.pi) / _TWO_PI * resolved_width)) + 2

        _project_frame(
            image=image,
            sphere_to_camera=sphere_to_camera,
            focal=focal,
            cx=cx,
            cy=cy,
            residual=residual,
            image_width=image_width,
            image_height=image_height,
            margin_x=margin_x,
            margin_y=margin_y,
            is_nadir=is_nadir,
            y_start=y_start,
            y_end=y_end,
            x_start=x_start,
            x_end=x_end,
            width=resolved_width,
            height=height,
            sin_lon=sin_lon,
            cos_lon=cos_lon,
            sin_lat=sin_lat,
            cos_lat=cos_lat,
            best_weight=best_weight,
            best_colour=best_colour,
            second_weight=second_weight,
            second_colour=second_colour,
            best_frame=best_frame,
            second_frame=second_frame,
            hits=hits,
            frame_index=frame_index,
        )
        stage(
            f"Projecting photographs: {frame_index + 1}/{len(frame_records)} "
            f"({int(time.monotonic() - started)}s elapsed)…"
        )

    projection_ms = lap_ms()
    stage("Blending panorama and encoding JPEG…")

    channel_gains = solve_channel_median_gains(
        pixel_count=pixel_count,
        frame_count=len(frame_records),
        best_frame=best_frame,
        second_frame=second_frame,
        best_weight=best_weight,
        second_weight=second_weight,
        best_colour=best_colour,
        second_colour=second_colour,
        min_weight=MIN_PIXEL_WEIGHT,
        image_width=resolved_width,
    )
    exposure_ms = lap_ms()

    output = np.zeros(pixel_count * 3, dtype=np.uint8)
    seam_stats = composite_seams(
        output=output,
        width=resolved_width,
        height=height,
        best_colour=best_colour,
        second_colour=second_colour,
        best_weight=best_weight,
        second_weight=second_weight,
        best_frame=best_frame,
        second_frame=second_frame,
        channel_gains=channel_gains,
        min_weight=MIN_PIXEL_WEIGHT,
        feather_px=SEAM_FEATHER_PX,
    )
    blend_ms = lap_ms()

    filled_pixels = fill_uncovered(
        output=output, best_weight=best_weight, width=resolved_width, height=height
    )
    fill_ms = lap_ms()

    stitcher_embedded = False
    if band_pano is not None:
        stitcher_embedded = _embed_stitcher_band(
            output=output, width=resolved_width, height=height, pano=band_pano
        )

    # ── Coverage audit ───────────────────────────────────────────────────
    hits_grid = hits.reshape(height, resolved_width)
    row_weight = cos_lat
    total_area = float((row_weight * resolved_width).sum())
    single_area = float((row_weight[:, None] * (hits_grid >= 1)).sum())
    double_area = float((row_weight[:, None] * (hits_grid >= 2)).sum())
    triple_area = float((row_weight[:, None] * (hits_grid >= 3)).sum())
    single = single_area / total_area
    double_coverage = double_area / total_area
    triple_coverage = triple_area / total_area

    gap_cols, gap_rows = 24, 12
    gap_cells = np.zeros(gap_cols * gap_rows, dtype=np.float64)
    uncovered_y, uncovered_x = np.nonzero(hits_grid == 0)
    worst_lat = 0.0
    worst_lon = 0.0
    if len(uncovered_y):
        weights = row_weight[uncovered_y]
        cell_rows = uncovered_y * gap_rows // height
        cell_cols = uncovered_x * gap_cols // resolved_width
        np.add.at(gap_cells, cell_rows * gap_cols + cell_cols, weights)
        # First pixel in scan order to reach the maximum row weight.
        max_weight = float(weights.max())
        candidate_rows = np.flatnonzero(row_weight >= max_weight)
        for row in candidate_rows:
            cols = uncovered_x[uncovered_y == row]
            if len(cols):
                worst_row = row
                worst_col = int(cols[0])
                worst_lat = 90 - (worst_row + 0.5) / height * 180
                worst_lon = -180 + (worst_col + 0.5) / resolved_width * 360
                break

    viewport = worst_viewport_gap(
        hits=hits, width=resolved_width, height=height
    )

    # ── Diagnostics, written whether the gate passes or not ──────────────
    palette = np.array(
        [(190, 40, 40), (235, 200, 60), (60, 110, 220), (40, 190, 180)],
        dtype=np.uint8,
    )
    map_rgb = palette[np.minimum(hits_grid, 3)]
    map_path = out_dir / "coverage_map.jpg"
    _encode_jpeg(map_path, resolved_width, height, map_rgb)

    ranked_gaps: list[dict] = []
    for cell in np.flatnonzero(gap_cells > 0):
        ranked_gaps.append(
            {
                "longitudeDeg": -180 + ((cell % gap_cols) + 0.5) / gap_cols * 360,
                "latitudeDeg": 90 - ((cell // gap_cols) + 0.5) / gap_rows * 180,
                "uncoveredAreaPercent": float(gap_cells[cell]) / total_area * 100,
            }
        )
    ranked_gaps.sort(key=lambda g: g["uncoveredAreaPercent"], reverse=True)

    report: dict = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "station": str(out_dir),
        "panorama": {
            "path": str(out_path),
            "width": resolved_width,
            "height": height,
            "aspect": "2:1 equirectangular",
        },
        "photographCount": len(frame_records),
        "verticalFovAssumedDeg": vertical_fov_deg,
        "resolution": {
            "requestedWidth": width,
            "width": resolved_width,
            "height": height,
            "accumulatorBytes": sphere_stitch_accumulator_bytes(resolved_width),
            "budgetBytes": ACCUMULATOR_BUDGET_BYTES,
            "downgraded": resolved_width != width,
        },
        "registration": {
            "enabled": refine_registration,
            "pairsConsidered": registration.pairs_considered,
            "acceptedEdges": registration.accepted_edges,
            "rejectedEdges": registration.rejected_edges,
            "featuresDetected": registration.feature_total,
            "maxCorrectionDeg": max_correction_deg(registration.correction_deg),
            "perFrameCorrectionDeg": list(registration.correction_deg),
        },
        "timingsMs": {
            "registration": registration_ms,
            "projection": projection_ms,
            "exposure": exposure_ms,
            "blend": blend_ms,
            "gapFill": fill_ms,
            "stitcherBand": stitcher_ms,
            "encode": -1,
            "total": int((time.monotonic() - started) * 1000),
        },
        "thresholdPercent": 99.5,
        "passed": single >= COVERAGE_THRESHOLD,
        "coveragePercent": {
            "single": single * 100,
            "double": double_coverage * 100,
            "triple": triple_coverage * 100,
        },
        "uncoveredPercent": (1 - single) * 100,
        "coverageMapPath": str(map_path),
        "worstViewportGapPercent": viewport.gap * 100,
        "worstViewportGapDirection": {
            "latitudeDeg": viewport.latitude_deg,
            "longitudeDeg": viewport.longitude_deg,
        },
        "worstViewportGapThresholdPercent": 25.0,
        "gapFilledPixels": filled_pixels,
        "colourGains": [
            [
                round(float(channel_gains[f * 3]), 3),
                round(float(channel_gains[f * 3 + 1]), 3),
                round(float(channel_gains[f * 3 + 2]), 3),
            ]
            for f in range(len(frame_records))
        ],
        "seamBlend": seam_stats.to_json(),
        "stitcher": {
            "ok": stitcher_embedded,
            "status": band_status,
            "panoSize": ""
            if band_pano is None
            else f"{band_pano.shape[1]}x{band_pano.shape[0]}",
            "embedded": stitcher_embedded,
            "bandFeatherPx": 40,
            "elapsedMs": stitcher_ms,
        },
    }
    if registration.notes:
        report["registration"]["notes"] = list(registration.notes)
    if single < 1:
        report["largestGap"] = {
            "longitudeDeg": worst_lon,
            "latitudeDeg": worst_lat,
        }
    report["uncoveredRegions"] = [
        {
            "longitudeDeg": f"{g['longitudeDeg']:.1f}",
            "latitudeDeg": f"{g['latitudeDeg']:.1f}",
            "uncoveredAreaPercent": f"{g['uncoveredAreaPercent']:.3f}",
        }
        for g in ranked_gaps[:6]
    ]
    try:
        (out_dir / "coverage_report.json").write_text(
            json.dumps(report, indent=2), encoding="utf-8"
        )
    except OSError:
        pass

    if strict_photo_coverage and filled_pixels > 0:
        return StitchOutcome(
            ok=False,
            message=(
                f"Panorama needs retakes: {filled_pixels} pixels had no original "
                "photograph and were filled synthetically. Open coverage_map.jpg and "
                "coverage_report.json for missing directions. Original photos are "
                "safe; no incomplete panorama was accepted."
            ),
            report=report,
            gap_filled_pixels=filled_pixels,
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )

    if single < COVERAGE_THRESHOLD:
        lon = _signed_round(worst_lon)
        lat = _signed_round(worst_lat)
        return StitchOutcome(
            ok=False,
            message=(
                f"The sphere is only {single * 100:.1f}% covered, "
                "so the panorama would have a hole. The largest gap is around "
                f"longitude {lon}°, latitude {lat}° — retake that direction. Every "
                "saved photograph has been kept."
            ),
            report=report,
            coverage_single=single,
            coverage_double=double_coverage,
            coverage_triple=triple_coverage,
            worst_viewport_gap=viewport.gap,
            gap_filled_pixels=filled_pixels,
            coverage_map_path=str(map_path),
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )

    if viewport.gap > VIEWPORT_GAP_THRESHOLD:
        lon = _signed_round(viewport.longitude_deg)
        lat = _signed_round(viewport.latitude_deg)
        return StitchOutcome(
            ok=False,
            message=(
                f"Looking towards longitude {lon}°, latitude {lat}° shows a view that is "
                f"{viewport.gap * 100:.0f}% empty — no photograph "
                "reached it, so the panorama would be invented there. Retake that "
                "direction. Every saved photograph has been kept."
            ),
            report=report,
            coverage_single=single,
            coverage_double=double_coverage,
            coverage_triple=triple_coverage,
            worst_viewport_gap=viewport.gap,
            gap_filled_pixels=filled_pixels,
            coverage_map_path=str(map_path),
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )

    encode_started = time.monotonic()
    if not _encode_jpeg(out_path, resolved_width, height, output.reshape(height, resolved_width, 3)):
        return StitchOutcome(
            ok=False, message="The panorama could not be saved.", report=report
        )
    encode_ms = int((time.monotonic() - encode_started) * 1000)
    report["timingsMs"]["encode"] = encode_ms
    report["timingsMs"]["total"] = int((time.monotonic() - started) * 1000)
    try:
        (out_dir / "coverage_report.json").write_text(
            json.dumps(report, indent=2), encoding="utf-8"
        )
    except OSError:
        pass

    refined_frames = sum(1 for d in registration.correction_deg if d > 0)
    message = (
        f"Panorama generated ({resolved_width}×{height}). Coverage "
        f"{single * 100:.1f}% single, "
        f"{double_coverage * 100:.1f}% double, "
        f"{triple_coverage * 100:.1f}% triple"
        + (f", {refined_frames} orientations refined" if refined_frames > 0 else "")
        + (
            f", worst view {viewport.gap * 100:.0f}% empty (retake that direction)"
            if viewport.gap > 0.02
            else ""
        )
        + "."
    )
    return StitchOutcome(
        ok=True,
        message=message,
        report=report,
        panorama_path=str(out_path),
        coverage_map_path=str(map_path),
        coverage_single=single,
        coverage_double=double_coverage,
        coverage_triple=triple_coverage,
        worst_viewport_gap=viewport.gap,
        gap_filled_pixels=filled_pixels,
        elapsed_ms=int((time.monotonic() - started) * 1000),
    )


def _signed_round(value: float) -> str:
    rounded = round(value)
    return f"+{rounded}" if rounded >= 0 else f"{rounded}"


def _quat_from_record(record: FrameRecord) -> Quat:
    return Quat.from_list(list(record.camera_orientation))


def _decoded_projection_for(
    record: FrameRecord, image_width: int, image_height: int, vertical_fov_deg: float
):
    return decoded_projection(
        decoded_width=image_width,
        decoded_height=image_height,
        saved_width=record.saved_width,
        saved_height=record.saved_height,
        source_width=record.source_width,
        source_height=record.source_height,
        vertical_fov_deg=vertical_fov_deg,
        crop_offset_x=record.crop_offset_x,
        crop_offset_y=record.crop_offset_y,
    )


def _clamp_int(value: int, minimum: int, maximum: int) -> int:
    return maximum if value > maximum else (minimum if value < minimum else value)


def _project_frame(
    *,
    image: np.ndarray,
    sphere_to_camera,
    focal: float,
    cx: float,
    cy: float,
    residual: SphereResidualAffine,
    image_width: int,
    image_height: int,
    margin_x: float,
    margin_y: float,
    is_nadir: bool,
    y_start: int,
    y_end: int,
    x_start: int,
    x_end: int,
    width: int,
    height: int,
    sin_lon: np.ndarray,
    cos_lon: np.ndarray,
    sin_lat: np.ndarray,
    cos_lat: np.ndarray,
    best_weight: np.ndarray,
    best_colour: np.ndarray,
    second_weight: np.ndarray,
    second_colour: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    hits: np.ndarray,
    frame_index: int,
) -> None:
    qx, qy, qz, qw = (
        sphere_to_camera.x,
        sphere_to_camera.y,
        sphere_to_camera.z,
        sphere_to_camera.w,
    )
    xi_window = np.arange(x_start, x_end + 1)
    x_window = xi_window % width  # one-wrap longitude, matching the Dart conditional
    sin_lon_w = sin_lon[x_window]
    cos_lon_w = cos_lon[x_window]

    row_block = 128
    for block_start in range(y_start, y_end + 1, row_block):
        block_end = min(y_end, block_start + row_block - 1)
        rows = np.arange(block_start, block_end + 1)
        dy = sin_lat[rows][:, None]
        dxz = cos_lat[rows][:, None]
        dx = sin_lon_w[None, :] * dxz
        dz = -cos_lon_w[None, :] * dxz
        # v' = v + 2w(u×v) + 2u×(u×v), vectorised.
        c0x = qy * dz - qz * dy
        c0y = qz * dx - qx * dz
        c0z = qx * dy - qy * dx
        c1x = qy * c0z - qz * c0y
        c1y = qz * c0x - qx * c0z
        c1z = qx * c0y - qy * c0x
        cam_x = dx + 2.0 * (qw * c0x + c1x)
        cam_y = dy + 2.0 * (qw * c0y + c1y)
        cam_z = dz + 2.0 * (qw * c0z + c1z)
        depth = -cam_z
        alive = depth > 0.05
        if not alive.any():
            continue
        safe_depth = np.where(alive, depth, 1.0)
        predicted_u = cx + focal * cam_x / safe_depth
        predicted_v = cy - focal * cam_y / safe_depth

        if not residual.is_identity:
            du, dv = residual.shift_at(predicted_u, predicted_v, image_width, image_height)
        else:
            du = np.zeros_like(predicted_u)
            dv = np.zeros_like(predicted_v)
        u = predicted_u + du
        v = predicted_v + dv
        alive &= (
            (u >= 0) & (u < image_width - 1) & (v >= 0) & (v < image_height - 1)
        )
        if not alive.any():
            continue

        u_safe = np.where(alive, u, 0.0)
        v_safe = np.where(alive, v, 0.0)
        u0 = np.floor(u_safe)
        v0 = np.floor(v_safe)
        du_f = u_safe - u0
        dv_f = v_safe - v0
        u0i = u0.astype(np.int64)
        v0i = v0.astype(np.int64)

        # BGR planes; the accumulator stores RGB. Advanced indexing copies only
        # the sampled window, so no full-plane float conversion is needed.
        img_r = image[:, :, 2]
        img_g = image[:, :, 1]
        img_b = image[:, :, 0]

        def lerp4(plane: np.ndarray) -> np.ndarray:
            c00 = plane[v0i, u0i]
            c10 = plane[v0i, u0i + 1]
            c01 = plane[v0i + 1, u0i]
            c11 = plane[v0i + 1, u0i + 1]
            return (
                c00 * (1 - du_f) * (1 - dv_f)
                + c10 * du_f * (1 - dv_f)
                + c01 * (1 - du_f) * dv_f
                + c11 * du_f * dv_f
            )

        r = lerp4(img_r)
        g = lerp4(img_g)
        b = lerp4(img_b)

        weight = _pow6(depth)
        if is_nadir:
            alive &= (
                (u >= 6) & (u <= image_width - 7) & (v >= 6) & (v <= image_height - 7)
            )
            if not alive.any():
                continue
            u_c = np.where(alive, u, cx)
            v_c = np.where(alive, v, cy)
            half_w = image_width / 2
            half_h = image_height / 2
            r_norm = np.sqrt(
                ((u_c - cx) / half_w) * ((u_c - cx) / half_w)
                + ((v_c - cy) / half_h) * ((v_c - cy) / half_h)
            )
            fade_zone = r_norm > 0.7
            hard_out = fade_zone & (r_norm >= 1.0)
            alive &= ~hard_out
            fade = np.where(
                fade_zone & alive,
                0.5 * (1 + np.cos(math.pi * (r_norm - 0.7) / 0.3)),
                1.0,
            )
            weight = weight * fade
            if not alive.any():
                continue
        weight = weight * _smooth_step(
            np.minimum(u_safe, image_width - 1 - u_safe) / margin_x
        )
        weight = weight * _smooth_step(
            np.minimum(v_safe, image_height - 1 - v_safe) / margin_y
        )
        alive &= weight > 0
        if not alive.any():
            continue

        flat_rows = rows[:, None] * width + x_window[None, :]
        index = flat_rows[alive]
        w_hit = weight[alive]
        r_hit = r[alive]
        g_hit = g[alive]
        b_hit = b[alive]

        hits[index] = np.minimum(hits[index] + 1, 3)

        better = w_hit > best_weight[index]
        idx_better = index[better]
        # Displace the current best into second before overwriting it.
        second_weight[idx_better] = best_weight[idx_better]
        second_frame[idx_better] = best_frame[idx_better]
        second_colour[idx_better * 3] = best_colour[idx_better * 3]
        second_colour[idx_better * 3 + 1] = best_colour[idx_better * 3 + 1]
        second_colour[idx_better * 3 + 2] = best_colour[idx_better * 3 + 2]
        best_weight[idx_better] = w_hit[better].astype(np.float32)
        best_frame[idx_better] = frame_index
        best_colour[idx_better * 3] = _dart_round(r_hit[better]).astype(np.uint8)
        best_colour[idx_better * 3 + 1] = _dart_round(g_hit[better]).astype(np.uint8)
        best_colour[idx_better * 3 + 2] = _dart_round(b_hit[better]).astype(np.uint8)

        rest = ~better
        idx_second = index[rest]
        takes_second = w_hit[rest] > second_weight[idx_second]
        idx_second = idx_second[takes_second]
        second_weight[idx_second] = w_hit[rest][takes_second].astype(np.float32)
        second_frame[idx_second] = frame_index
        second_colour[idx_second * 3] = _dart_round(r_hit[rest][takes_second]).astype(np.uint8)
        second_colour[idx_second * 3 + 1] = _dart_round(g_hit[rest][takes_second]).astype(np.uint8)
        second_colour[idx_second * 3 + 2] = _dart_round(b_hit[rest][takes_second]).astype(np.uint8)


def solve_channel_median_gains(
    *,
    pixel_count: int,
    frame_count: int,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    best_weight: np.ndarray,
    second_weight: np.ndarray,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    min_weight: float = 0.0,
    image_width: int | None = None,
) -> list[float]:
    """Per-frame per-channel gains from log-ratio histograms over true overlaps."""
    bins = 141
    min_log_ratio = -0.70
    max_log_ratio = 0.70
    min_samples = 48
    max_iqr = 0.17
    chroma_tolerance = 0.42
    max_local_gradient = 12.0
    ridge_weight = 0.075
    min_frame_gain = 0.72
    max_frame_gain = 1.38
    max_chroma_log = 0.13

    gains = [1.0] * (frame_count * 3)
    if frame_count < 2 or pixel_count < 1:
        return gains

    indices = np.arange(0, pixel_count, 3)
    best = best_frame[indices].astype(np.int64)
    second = second_frame[indices].astype(np.int64)
    valid = (
        (best >= 0)
        & (second >= 0)
        & (best != second)
        & (best < frame_count)
        & (second < frame_count)
    )
    wb = best_weight[indices].astype(np.float64)
    ws = second_weight[indices].astype(np.float64)
    valid &= (wb > min_weight) & (ws > min_weight) & (ws >= wb * 0.35)

    if image_width is not None and image_width > 1:
        columns = indices % image_width
        valid &= columns != (image_width - 1)
        valid &= indices + 1 < pixel_count
        nxt = np.minimum(indices + 1, pixel_count - 1)
        valid &= (best_frame[nxt] == best) & (second_frame[nxt] == second)
        off = indices * 3
        nxt_off = nxt * 3
        for c in range(3):
            valid &= (
                np.abs(
                    best_colour[off + c].astype(np.int32)
                    - best_colour[nxt_off + c].astype(np.int32)
                )
                <= max_local_gradient
            )
            valid &= (
                np.abs(
                    second_colour[off + c].astype(np.int32)
                    - second_colour[nxt_off + c].astype(np.int32)
                )
                <= max_local_gradient
            )

    indices = indices[valid]
    best = best[valid]
    second = second[valid]
    if len(indices) == 0:
        return gains

    off = indices * 3
    bc = best_colour.reshape(pixel_count, 3)[indices].astype(np.float64)
    sc = second_colour.reshape(pixel_count, 3)[indices].astype(np.float64)
    r1, g1, b1 = bc[:, 0], bc[:, 1], bc[:, 2]
    r2, g2, b2 = sc[:, 0], sc[:, 1], sc[:, 2]

    in_range = (
        (r1 >= 15) & (g1 >= 15) & (b1 >= 15)
        & (r2 >= 15) & (g2 >= 15) & (b2 >= 15)
        & (r1 <= 245) & (g1 <= 245) & (b1 <= 245)
        & (r2 <= 245) & (g2 <= 245) & (b2 <= 245)
    )
    y1 = 0.2126 * r1 + 0.7152 * g1 + 0.0722 * b1
    y2 = 0.2126 * r2 + 0.7152 * g2 + 0.0722 * b2
    in_range &= (y1 >= 22) & (y2 >= 22) & (y1 <= 240) & (y2 <= 240)
    luminance_ratio = np.where((y1 > 0) & (y2 > 0), y1 / np.maximum(y2, 1e-9), 0.0)
    in_range &= (luminance_ratio >= 0.50) & (luminance_ratio <= 2.0)
    safe_y1 = np.maximum(y1, 1e-9)
    safe_y2 = np.maximum(y2, 1e-9)
    for a, b in ((r1, r2), (g1, g2), (b1, b2)):
        in_range &= np.abs(a / safe_y1 - b / safe_y2) <= chroma_tolerance
    keep = in_range
    if not keep.any():
        return gains
    indices, best, second = indices[keep], best[keep], second[keep]
    r1, g1, b1 = r1[keep], g1[keep], b1[keep]
    r2, g2, b2 = r2[keep], g2[keep], b2[keep]

    lower_is_best = best < second
    denom = np.where(lower_is_best, np.where(r2 != 0, r2, 1), np.where(r1 != 0, r1, 1))
    log_r = np.log(np.where(lower_is_best, r1, r2) / denom)
    denom_g = np.where(lower_is_best, np.where(g2 != 0, g2, 1), np.where(g1 != 0, g1, 1))
    log_g = np.log(np.where(lower_is_best, g1, g2) / denom_g)
    denom_b = np.where(lower_is_best, np.where(b2 != 0, b2, 1), np.where(b1 != 0, b1, 1))
    log_b = np.log(np.where(lower_is_best, b1, b2) / denom_b)

    span = max_log_ratio - min_log_ratio
    in_hist = (
        (log_r >= min_log_ratio) & (log_r <= max_log_ratio)
        & (log_g >= min_log_ratio) & (log_g <= max_log_ratio)
        & (log_b >= min_log_ratio) & (log_b <= max_log_ratio)
    )
    if not in_hist.any():
        return gains
    best, second = best[in_hist], second[in_hist]
    log_r, log_g, log_b = log_r[in_hist], log_g[in_hist], log_b[in_hist]
    lower_is_best = lower_is_best[in_hist]

    r_bin = _dart_round((log_r - min_log_ratio) / span * (bins - 1)).astype(np.int64)
    g_bin = _dart_round((log_g - min_log_ratio) / span * (bins - 1)).astype(np.int64)
    b_bin = _dart_round((log_b - min_log_ratio) / span * (bins - 1)).astype(np.int64)

    pair_a = np.where(lower_is_best, best, second)
    pair_b = np.where(lower_is_best, second, best)
    key = pair_a * frame_count + pair_b

    stride = 3 * bins
    flat = np.concatenate([
        key * stride + c * bins + bin_values
        for c, bin_values in enumerate((r_bin, g_bin, b_bin))
    ])
    flat_hist = np.bincount(flat)
    pair_counts = np.bincount(key)
    max_key = len(pair_counts)

    def quantile_bin(hist: np.ndarray, start: int, count: int, fraction: float) -> int:
        target = max(1, math.ceil(count * fraction))
        cumulative = 0
        for j in range(bins):
            cumulative += int(hist[start + j])
            if cumulative >= target:
                return j
        return bins - 1

    edges: list[tuple[int, int, float, list[float]]] = []
    for key_value in np.flatnonzero(pair_counts):
        count = int(pair_counts[key_value])
        if count < min_samples:
            continue
        hist = flat_hist[key_value * stride : (key_value + 1) * stride]
        if len(hist) < stride:
            hist = np.concatenate([hist, np.zeros(stride - len(hist), dtype=flat_hist.dtype)])
        ratios = []
        channel_ok = True
        for c in range(3):
            start = c * bins
            q1 = quantile_bin(hist, start, count, 0.25)
            median = quantile_bin(hist, start, count, 0.50)
            q3 = quantile_bin(hist, start, count, 0.75)
            spread = (q3 - q1) * span / (bins - 1)
            if spread > max_iqr:
                channel_ok = False
                break
            ratios.append(min_log_ratio + median * span / (bins - 1))
        if not channel_ok:
            continue
        edges.append(
            (
                int(key_value // frame_count),
                int(key_value % frame_count),
                min(1.0, count / 300.0),
                ratios,
            )
        )
    if not edges:
        return gains

    # In-place Gauss–Seidel over the edges, matching the Dart update order:
    # earlier frames' new values are visible to later frames within a pass.
    solved = [[0.0 for _ in range(frame_count)] for _ in range(3)]
    for channel in range(3):
        x = solved[channel]
        for _pass in range(90):
            largest_change = 0.0
            for f in range(frame_count):
                numerator = 0.0
                denominator = ridge_weight
                for a, b, weight, ratios in edges:
                    if a == f:
                        numerator += weight * (x[b] - ratios[channel])
                        denominator += weight
                    elif b == f:
                        numerator += weight * (x[a] + ratios[channel])
                        denominator += weight
                nxt = numerator / denominator
                largest_change = max(largest_change, abs(nxt - x[f]))
                x[f] = nxt
            if largest_change < 0.00005:
                break

    min_log_gain = math.log(min_frame_gain)
    max_log_gain = math.log(max_frame_gain)
    for f in range(frame_count):
        mean = (solved[0][f] + solved[1][f] + solved[2][f]) / 3
        for c in range(3):
            chroma = min(max_chroma_log, max(-max_chroma_log, solved[c][f] - mean))
            corrected = min(max_log_gain, max(min_log_gain, mean + chroma))
            gains[f * 3 + c] = math.exp(corrected)
    return gains


def fill_uncovered(
    *,
    output: np.ndarray,
    best_weight: np.ndarray,
    width: int,
    height: int,
) -> int:
    """BFS colour propagation from the covered boundary, then 3 box blurs."""
    pixel_count = width * height
    covered = best_weight > MIN_PIXEL_WEIGHT
    uncovered_count = int((~covered).sum())
    if uncovered_count == 0:
        return 0

    covered_mask = covered.copy()
    out_grid = output.reshape(height, width, 3)
    queue: deque[int] = deque()
    queued = np.zeros(pixel_count, dtype=bool)

    def enqueue(index: int) -> None:
        if covered_mask[index] or queued[index]:
            return
        queued[index] = True
        queue.append(index)

    hits_grid = covered_mask.reshape(height, width)
    for y in range(height):
        row = y * width
        for x in range(width):
            i = row + x
            if hits_grid[y, x]:
                continue
            left = width - 1 if x == 0 else x - 1
            right = 0 if x == width - 1 else x + 1
            if (
                hits_grid[y, left]
                or hits_grid[y, right]
                or (y > 0 and hits_grid[y - 1, x])
                or (y < height - 1 and hits_grid[y + 1, x])
            ):
                enqueue(i)

    filled = 0
    while queue:
        i = queue.popleft()
        if covered_mask[i]:
            continue
        x = i % width
        y = i // width
        left = width - 1 if x == 0 else x - 1
        right = 0 if x == width - 1 else x + 1
        neighbours = [y * width + left, y * width + right]
        if y > 0:
            neighbours.append(i - width)
        if y < height - 1:
            neighbours.append(i + width)
        r_sum = g_sum = b_sum = 0
        count = 0
        for j in neighbours:
            if not covered_mask[j]:
                continue
            r_sum += int(output[j * 3])
            g_sum += int(output[j * 3 + 1])
            b_sum += int(output[j * 3 + 2])
            count += 1
        if count == 0:
            continue
        output[i * 3] = int(_round_half(r_sum / count))
        output[i * 3 + 1] = int(_round_half(g_sum / count))
        output[i * 3 + 2] = int(_round_half(b_sum / count))
        covered_mask[i] = True
        filled += 1
        for j in neighbours:
            enqueue(j)

    if filled > 0:
        filled_mask = (best_weight <= MIN_PIXEL_WEIGHT)
        _smooth_region(output, filled_mask, width, height, 3)
    return filled


def _round_half(value: float) -> int:
    return math.floor(value + 0.5)


def _smooth_region(
    output: np.ndarray,
    mask: np.ndarray,
    width: int,
    height: int,
    passes: int,
) -> None:
    grid = output.reshape(height, width, 3)
    mask_grid = mask.reshape(height, width)
    # The Dart divides by the number of *sampled* neighbours (9 interior,
    # 6 at the clamped pole rows), not by the number of masked ones.
    count = np.full((height, width), 9.0)
    if height >= 2:
        count[0] = 6.0
        count[height - 1] = 6.0
    if height == 1:
        count[0] = 3.0
    source = grid.astype(np.float64)
    for _pass in range(passes):
        padded = np.zeros((height, width, 3), dtype=np.float64)
        for dy in (-1, 0, 1):
            ny = slice(max(0, dy), height + min(0, dy))
            ty = slice(max(0, -dy), height + min(0, -dy))
            rows_n = source[ny]
            padded[ty] += np.roll(rows_n, 1, axis=1) + np.roll(rows_n, -1, axis=1) + rows_n
        averaged = padded / count[:, :, None]
        target = grid.copy()
        update = mask_grid
        target[update] = _dart_round(averaged[update]).astype(np.uint8)
        grid[:] = target
        source = grid.astype(np.float64)


@dataclass(frozen=True, slots=True)
class ViewportGap:
    gap: float
    latitude_deg: float
    longitude_deg: float


def worst_viewport_gap(
    *,
    hits: np.ndarray,
    width: int,
    height: int,
) -> ViewportGap:
    sample_count = 6000
    view_count = 300
    half_fov_cos = 0.7071067811865476

    sequence = np.arange(sample_count)
    z = 1 - 2 * (sequence + 0.5) / sample_count
    radius = np.sqrt(np.maximum(0.0, 1 - z * z))
    theta = math.pi * (3 - math.sqrt(5)) * sequence
    dx = np.cos(theta) * radius
    dy = np.sin(theta) * radius
    dz = z

    lat = np.arcsin(z)
    lon = np.arctan2(dx, -dz)
    px = np.floor((lon + math.pi) / _TWO_PI * width).astype(np.int64)
    py = np.floor((math.pi / 2 - lat) / math.pi * height).astype(np.int64)
    px = np.clip(px, 0, width - 1)
    py = np.clip(py, 0, height - 1)
    covered = hits[py * width + px] > 0

    centres = np.arange(view_count) * sample_count // view_count
    cx = dx[centres]
    cy = dy[centres]
    cz = dz[centres]
    dots = np.stack([cx, cy, cz]).T @ np.stack([dx, dy, dz])  # (views, samples)
    in_view = dots >= half_fov_cos
    seen = in_view.sum(axis=1)
    seen_covered = (in_view & covered[None, :]).sum(axis=1)
    eligible = seen >= 32
    gaps = np.where(eligible, (seen - seen_covered) / np.maximum(seen, 1), -1.0)
    best_view = int(np.argmax(gaps))
    if gaps[best_view] <= 0:
        return ViewportGap(gap=0.0, latitude_deg=0.0, longitude_deg=0.0)
    return ViewportGap(
        gap=float(gaps[best_view]),
        latitude_deg=math.degrees(math.asin(min(1.0, max(-1.0, cz[best_view])))),
        longitude_deg=math.degrees(math.atan2(cx[best_view], -cz[best_view])),
    )


def _encode_jpeg(path: Path, width: int, height: int, rgb: np.ndarray) -> bool:
    if rgb.ndim == 1:
        image = rgb.reshape(height, width, 3)
    else:
        image = rgb
    bgr = cv2.cvtColor(image, cv2.COLOR_RGB2BGR)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(path), bgr):
            return False
    except Exception:
        return False
    return path.exists() and path.stat().st_size > 0


def _stitch_ring_with_opencv(records: list[dict], progress):
    """Optional cv2.Stitcher band over the 36 ring frames. Off by default."""
    ring_paths = []
    for i, record in enumerate(records):
        if i == 12 or i == 37:
            continue
        path = record.get("imagePath")
        if not path or not Path(path).exists():
            continue
        ring_paths.append(path)
    if len(ring_paths) != 36:
        return None, "skipped"

    mats = []
    for path in ring_paths:
        source = cv2.imread(path, cv2.IMREAD_COLOR)
        if source is None or source.size == 0:
            return None, "decode-failed"
        scale = _STITCHER_SHORT_SIDE_PX / min(source.shape[1], source.shape[0])
        target_width = int(math.floor(source.shape[1] * scale + 0.5))
        target_height = int(math.floor(source.shape[0] * scale + 0.5))
        mats.append(
            cv2.resize(source, (target_width, target_height), interpolation=cv2.INTER_AREA)
        )
    try:
        stitcher = cv2.Stitcher.create(cv2.Stitcher_PANORAMA)
        stitcher.setPanoConfidenceThresh(0.35)
        status, pano = stitcher.stitch(mats)
        status_names = {
            0: "OK",
            1: "ERR_NEED_MORE_IMGS",
            2: "ERR_HOMOGRAPHY_EST_FAIL",
            3: "ERR_CAMERA_PARAMS_ADJUST_FAIL",
        }
        status_name = status_names.get(int(status), str(status))
        if status != 0 or pano is None or pano.size == 0:
            return None, status_name
        return pano, status_name
    except Exception:
        return None, "exception"


def _embed_stitcher_band(
    *,
    output: np.ndarray,
    width: int,
    height: int,
    pano: np.ndarray,
) -> bool:
    aspect = pano.shape[1] / pano.shape[0]
    if aspect < 2.0 or aspect > 4.6:
        return False
    lat_span = 2 * math.pi / aspect
    scaled_height = max(1, int(math.floor(width / aspect + 0.5)))
    scaled = cv2.resize(pano, (width, scaled_height), interpolation=cv2.INTER_LINEAR)
    top_raw = int(math.floor((0.5 - lat_span / 2 / math.pi) * height + 0.5))
    top_limit = max(0, height - scaled_height)
    top_row = min(max(top_raw, 0), top_limit)
    bottom_row = min(height, top_row + scaled_height)
    if bottom_row - top_row < _STITCHER_BAND_FEATHER_PX * 3:
        return False

    half_band = (bottom_row - top_row) // 2
    sample_top = top_row + half_band // 2
    sample_bottom = sample_top + half_band
    pose_grid = output.reshape(height, width, 3)
    # The reference implementation weights the BGR panorama with RGB luminance
    # weights; the quirk is preserved so A/B runs stay comparable.
    pose_signal = (
        0.299 * pose_grid[sample_top:sample_bottom:4, :, 0].astype(np.float64)
        + 0.587 * pose_grid[sample_top:sample_bottom:4, :, 1].astype(np.float64)
        + 0.114 * pose_grid[sample_top:sample_bottom:4, :, 2].astype(np.float64)
    ).sum(axis=0)
    pano_signal = (
        0.299 * scaled[sample_top - top_row : sample_bottom - top_row : 4, :, 0].astype(np.float64)
        + 0.587 * scaled[sample_top - top_row : sample_bottom - top_row : 4, :, 1].astype(np.float64)
        + 0.114 * scaled[sample_top - top_row : sample_bottom - top_row : 4, :, 2].astype(np.float64)
    ).sum(axis=0)
    if len(pose_signal) == 0:
        return False
    shift = _estimate_band_shift(pose_signal, pano_signal, width)

    columns = np.arange(width)
    sx = (columns - shift) % width
    pano_band = scaled[top_row - top_row : bottom_row - top_row, sx, :].astype(np.float64)
    pose_band = pose_grid[top_row:bottom_row].astype(np.float64)
    rows = np.arange(top_row, bottom_row)
    from_top = (rows - top_row).astype(np.float64)
    from_bottom = (bottom_row - 1 - rows).astype(np.float64)
    w = np.ones(len(rows))
    w = np.minimum(w, np.where(from_top < _STITCHER_BAND_FEATHER_PX, from_top / _STITCHER_BAND_FEATHER_PX, w))
    w = np.minimum(w, np.where(from_bottom < _STITCHER_BAND_FEATHER_PX, from_bottom / _STITCHER_BAND_FEATHER_PX, w))
    t = (w * w * (3 - 2 * w))[:, None, None]
    blended = pose_band + (pano_band - pose_band) * t
    pose_grid[top_row:bottom_row] = _dart_round(blended).astype(np.uint8)
    return True


def _estimate_band_shift(pose_signal: np.ndarray, pano_signal: np.ndarray, width: int) -> int:
    def normalise(signal: np.ndarray) -> np.ndarray:
        mean = signal.mean()
        signal = signal - mean
        std = math.sqrt(float((signal * signal).mean()))
        if std > 1e-9:
            signal = signal / std
        return signal

    pose = normalise(pose_signal.astype(np.float64))
    pano = normalise(pano_signal.astype(np.float64))
    best_shift = 0
    best_score = -math.inf
    for d in range(width):
        score = float(np.roll(pose, -d) @ pano)
        if score > best_score:
            best_score = score
            best_shift = d
    return best_shift
