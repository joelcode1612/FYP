"""Spherical coverage measured from projected footprints.

## What is measured, and on what

Coverage is the fraction of the sphere for which at least one photograph
contains the direction. It is computed by projecting every frame's rectangle
onto the unit sphere and counting how many frames see each sample of an
**equal-area** grid — so a polar cell counts exactly as much as an equatorial
one.

Two numbers matter separately:

* **single coverage** — is the sphere covered at all? A hole here is a hole in
  the panorama.
* **double coverage** — is there a seam band to blend in? A sphere covered
  exactly once has every boundary between two photographs as a hard cut, which
  is where brightness bands and tearing appear.

## Precision

The report carries its own resolution and tolerance. A figure of 99.5% is
reported as 99.5%, never rounded to 100%: the tolerance is one cell, and a
region narrower than a cell can be missed entirely. Coverage is therefore only
ever quoted to the resolution it was measured at.

## Largest uncovered region

The equal-area grid is not a regular lattice, so connected components are
computed on a separate 0.5° latitude/longitude raster (longitude wrapping at
±180°) and area-weighted by ``cos(latitude)``. That raster is for connectivity
only; it is not the source of the headline percentages.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field

import numpy as np

from ..sphere_math import Quat
from .camera import (
    DEFAULT_GRID_CELLS,
    EqualAreaGrid,
    PinholeCamera,
    coverage_grid,
    frame_visible,
)

#: Resolution of the connectivity raster used for the largest-hole analysis.
HOLE_RASTER_STEP_DEG = 0.5
#: A latitude band this close to a pole is reported as "zenith"/"nadir".
POLE_BAND_DEG = 75.0
#: The horizon band whose coverage decides horizontal loop continuity.
HORIZON_BAND_DEG = 20.0
#: Below this double-coverage fraction the seam band is reported as thin.
THIN_SEAM_THRESHOLD = 0.90


@dataclass(frozen=True, slots=True)
class FrameFootprint:
    """One photograph's placement on the sphere."""

    target_id: int
    rotation: Quat
    camera: PinholeCamera


@dataclass(frozen=True, slots=True)
class CoverageRegion:
    """A contiguous uncovered or thinly-covered region."""

    area_fraction: float
    centre_latitude_deg: float
    centre_longitude_deg: float
    latitude_span_deg: float
    longitude_span_deg: float
    cells: int

    def as_dict(self) -> dict[str, object]:
        return {
            "areaFraction": round(self.area_fraction, 5),
            "centreLatitudeDeg": round(self.centre_latitude_deg, 2),
            "centreLongitudeDeg": round(self.centre_longitude_deg, 2),
            "latitudeSpanDeg": round(self.latitude_span_deg, 2),
            "longitudeSpanDeg": round(self.longitude_span_deg, 2),
            "cells": self.cells,
        }


@dataclass
class CoverageReport:
    """Everything the capture gate and the quality report need."""

    single: float
    double: float
    triple: float
    uncovered: float
    largest_uncovered: CoverageRegion | None
    uncovered_regions: list[CoverageRegion]
    thin_regions: list[CoverageRegion]
    upper_hemisphere: float
    lower_hemisphere: float
    zenith: float
    nadir: float
    horizon_band: float
    grid_cells: int
    resolution_deg: float
    tolerance: float
    per_frame_fraction: dict[int, float] = field(default_factory=dict)
    total_footprint_sr: float = 0.0

    @property
    def is_complete(self) -> bool:
        """True only when every sampled direction is covered.

        Deliberately strict: ``>= 1.0`` rather than ``>= 0.999``. A sphere with
        an unsampled direction is not reported as complete, however small the
        gap.
        """
        return self.uncovered == 0.0

    @property
    def has_seam_band(self) -> bool:
        return self.double >= THIN_SEAM_THRESHOLD

    @property
    def quality_state(self) -> str:
        if self.uncovered > 0.005:
            return "incomplete"
        if self.uncovered > 0.0:
            return "nearly_complete"
        if self.double < THIN_SEAM_THRESHOLD:
            return "complete_thin_seams"
        return "complete"

    def as_dict(self) -> dict[str, object]:
        return {
            "single": round(self.single, 5),
            "double": round(self.double, 5),
            "triple": round(self.triple, 5),
            "uncovered": round(self.uncovered, 6),
            "largestUncovered": (
                self.largest_uncovered.as_dict() if self.largest_uncovered else None
            ),
            "uncoveredRegions": [r.as_dict() for r in self.uncovered_regions[:8]],
            "thinRegions": [r.as_dict() for r in self.thin_regions[:8]],
            "upperHemisphere": round(self.upper_hemisphere, 5),
            "lowerHemisphere": round(self.lower_hemisphere, 5),
            "zenith": round(self.zenith, 5),
            "nadir": round(self.nadir, 5),
            "horizonBand": round(self.horizon_band, 5),
            "gridCells": self.grid_cells,
            "resolutionDeg": round(self.resolution_deg, 3),
            "tolerance": round(self.tolerance, 8),
            "state": self.quality_state,
            "complete": self.is_complete,
            "hasSeamBand": self.has_seam_band,
            "perFrameFraction": {
                str(k): round(v, 5) for k, v in sorted(self.per_frame_fraction.items())
            },
        }


def _lat_lon_raster(
    footprints: list[FrameFootprint], step_deg: float
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Coverage counts on a regular lat/lon raster, plus its cell areas."""
    step = max(0.05, float(step_deg))
    rows = int(round(180.0 / step))
    columns = int(round(360.0 / step))
    latitudes = -90.0 + (np.arange(rows) + 0.5) * step
    longitudes = -180.0 + (np.arange(columns) + 0.5) * step
    lat_grid, lon_grid = np.meshgrid(
        np.radians(latitudes), np.radians(longitudes), indexing="ij"
    )
    cos_lat = np.cos(lat_grid)
    directions = np.stack(
        [cos_lat * np.cos(lon_grid), np.sin(lat_grid), cos_lat * np.sin(lon_grid)],
        axis=-1,
    ).reshape(-1, 3)
    counts = np.zeros(directions.shape[0], dtype=np.int32)
    for footprint in footprints:
        counts += frame_visible(footprint.rotation, footprint.camera, directions).astype(np.int32)
    counts = counts.reshape(rows, columns)
    areas = cos_lat * (math.radians(step) ** 2)
    return counts, areas, latitudes


def _regions_from_mask(
    mask: np.ndarray,
    areas: np.ndarray,
    latitudes: np.ndarray,
    step_deg: float,
    *,
    limit: int = 8,
) -> list[CoverageRegion]:
    """Connected components of [mask], area-weighted, largest first."""
    rows, columns = mask.shape
    total_area = float(areas.sum())
    if total_area <= 0:
        return []
    visited = np.zeros_like(mask, dtype=bool)
    regions: list[CoverageRegion] = []
    for row in range(rows):
        for column in range(columns):
            if not mask[row, column] or visited[row, column]:
                continue
            queue = deque([(row, column)])
            visited[row, column] = True
            cells: list[tuple[int, int]] = []
            area = 0.0
            while queue:
                r, c = queue.popleft()
                cells.append((r, c))
                area += float(areas[r, c])
                for dr in (-1, 0, 1):
                    for dc in (-1, 0, 1):
                        if dr == 0 and dc == 0:
                            continue
                        nr = r + dr
                        nc = (c + dc) % columns  # longitude wraps
                        if 0 <= nr < rows and mask[nr, nc] and not visited[nr, nc]:
                            visited[nr, nc] = True
                            queue.append((nr, nc))
            if not cells:
                continue
            lat_values = [latitudes[r] for r, _c in cells]
            lon_values = [(c + 0.5) * step_deg - 180.0 for _r, c in cells]
            # Longitude span must respect the wrap, so use the widest gap.
            ordered = sorted(v % 360.0 for v in lon_values)
            widest_gap = 0.0
            gap_start = ordered[0]
            for index, value in enumerate(ordered):
                nxt = ordered[(index + 1) % len(ordered)]
                gap = (nxt - value) % 360.0
                if gap > widest_gap:
                    widest_gap = gap
                    gap_start = nxt
            span = 360.0 - widest_gap
            centre_lon = (gap_start + span / 2.0) % 360.0
            if centre_lon > 180.0:
                centre_lon -= 360.0
            regions.append(
                CoverageRegion(
                    area_fraction=area / total_area,
                    centre_latitude_deg=float(np.mean(lat_values)),
                    centre_longitude_deg=float(centre_lon),
                    latitude_span_deg=float(max(lat_values) - min(lat_values) + step_deg),
                    longitude_span_deg=float(span),
                    cells=len(cells),
                )
            )
    regions.sort(key=lambda r: -r.area_fraction)
    return regions[:limit]


def measure_coverage(
    footprints: list[FrameFootprint],
    *,
    cells: int = DEFAULT_GRID_CELLS,
    grid: EqualAreaGrid | None = None,
    hole_step_deg: float = HOLE_RASTER_STEP_DEG,
) -> CoverageReport:
    """Measure single/double coverage and the geometry of what is missing."""
    resolved = grid or coverage_grid(cells)
    directions = resolved.directions
    counts = np.zeros(resolved.cells, dtype=np.int32)
    per_frame: dict[int, float] = {}
    total_sr = 0.0
    for footprint in footprints:
        visible = frame_visible(footprint.rotation, footprint.camera, directions)
        counts += visible.astype(np.int32)
        fraction = float(visible.mean())
        per_frame[footprint.target_id] = fraction
        total_sr += fraction * 4.0 * math.pi

    single = float(np.mean(counts >= 1))
    double = float(np.mean(counts >= 2))
    triple = float(np.mean(counts >= 3))
    uncovered = float(np.mean(counts == 0))

    z = directions[:, 1]
    lat = np.degrees(np.arcsin(np.clip(z, -1.0, 1.0)))
    upper = float(np.mean((counts >= 1)[lat > 0])) if np.any(lat > 0) else 0.0
    lower = float(np.mean((counts >= 1)[lat < 0])) if np.any(lat < 0) else 0.0
    zenith = float(np.mean((counts >= 1)[lat >= POLE_BAND_DEG])) if np.any(lat >= POLE_BAND_DEG) else 0.0
    nadir = (
        float(np.mean((counts >= 1)[lat <= -POLE_BAND_DEG]))
        if np.any(lat <= -POLE_BAND_DEG)
        else 0.0
    )
    horizon = (
        float(np.mean((counts >= 1)[np.abs(lat) <= HORIZON_BAND_DEG]))
        if np.any(np.abs(lat) <= HORIZON_BAND_DEG)
        else 0.0
    )

    raster_counts, areas, latitudes = _lat_lon_raster(footprints, hole_step_deg)
    uncovered_mask = raster_counts == 0
    uncovered_regions = _regions_from_mask(
        uncovered_mask, areas, latitudes, hole_step_deg
    )
    thin_mask = raster_counts == 1
    thin_regions = _regions_from_mask(thin_mask, areas, latitudes, hole_step_deg)

    return CoverageReport(
        single=single,
        double=double,
        triple=triple,
        uncovered=uncovered,
        largest_uncovered=uncovered_regions[0] if uncovered_regions else None,
        uncovered_regions=uncovered_regions,
        thin_regions=thin_regions,
        upper_hemisphere=upper,
        lower_hemisphere=lower,
        zenith=zenith,
        nadir=nadir,
        horizon_band=horizon,
        grid_cells=resolved.cells,
        resolution_deg=resolved.resolution_deg,
        tolerance=resolved.tolerance,
        per_frame_fraction=per_frame,
        total_footprint_sr=total_sr,
    )


def suggest_extra_directions(
    report: CoverageReport,
    *,
    limit: int = 4,
    min_area_fraction: float = 0.0015,
) -> list[tuple[float, float]]:
    """``(yaw_deg, pitch_deg)`` directions that would fill the largest holes.

    A hole smaller than ``min_area_fraction`` is not worth another photograph;
    adding targets for it would trade a real capture for a cosmetic figure.
    """
    suggestions: list[tuple[float, float]] = []
    for region in report.uncovered_regions:
        if region.area_fraction < min_area_fraction:
            continue
        suggestions.append(
            (region.centre_longitude_deg, region.centre_latitude_deg)
        )
        if len(suggestions) >= limit:
            break
    return suggestions


__all__ = [
    "CoverageRegion",
    "CoverageReport",
    "FrameFootprint",
    "HORIZON_BAND_DEG",
    "POLE_BAND_DEG",
    "THIN_SEAM_THRESHOLD",
    "measure_coverage",
    "suggest_extra_directions",
]
