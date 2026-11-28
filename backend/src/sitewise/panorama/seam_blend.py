"""Seam selection and owner-driven compositing for the equirectangular canvas.

Faithful port of ``lib/features/sphere_capture/domain/seam_blend.dart``.

Every pixel is owned by exactly one frame — the graph cut decides which side
of an object the boundary passes, a per-row polish moves it the last few
pixels, and a narrow Gaussian feather cross-fades only where the two frames
agree. The heavy per-pixel passes are vectorised with numpy but reproduce the
Dart loop semantics exactly, including the strict-inequality merge order and
the half-away-from-zero rounding of the byte clamp.
"""

from __future__ import annotations

import math

import numpy as np

from .graph_cut_seams import (
    SeamEnergyMaps,
    build_seam_energy,
    find_seam_labels,
    seam_pixel_cost_at,
)

SEAM_COST_WEIGHT = 2.0
GHOST_VISIBLE_DELTA = 24.0
SEAM_FEATHER_PX = 6
SEAM_GAUSSIAN_SIGMA_PX = 4.0
SEAM_SEARCH_RADIUS = 8

_A1 = 0.254829592
_A2 = -0.284496736
_A3 = 1.421413741
_A4 = -1.453152027
_A5 = 1.061405429
_P = 0.3275911
_SQRT2 = math.sqrt(2)


def _seam_gaussian(normalised_distance: float | np.ndarray):
    """erf(d/(σ√2)) via Abramowitz–Stegun 7.1.26, saturated at 3σ."""
    d_sigma = normalised_distance * (SEAM_FEATHER_PX / SEAM_GAUSSIAN_SIGMA_PX)
    x = np.maximum(d_sigma, 0.0)
    out = np.ones_like(x)
    within = x < 3.0
    xw = x[within]
    z = xw / _SQRT2
    t = 1.0 / (1.0 + _P * z)
    erf = 1.0 - ((((_A5 * t + _A4) * t + _A3) * t + _A2) * t + _A1) * t * np.exp(-z * z)
    out[within] = np.clip(erf, 0.0, 1.0)
    return out


def _seam_gaussian_scalar(normalised_distance: float) -> float:
    d_sigma = normalised_distance * (SEAM_FEATHER_PX / SEAM_GAUSSIAN_SIGMA_PX)
    x = d_sigma if d_sigma > 0 else 0.0
    if x >= 3.0:
        return 1.0
    z = x / _SQRT2
    t = 1.0 / (1.0 + _P * z)
    erf = 1.0 - ((((_A5 * t + _A4) * t + _A3) * t + _A2) * t + _A1) * t * math.exp(-z * z)
    return min(1.0, max(0.0, erf))


def _clamp_bytes(values: np.ndarray) -> np.ndarray:
    """Dart `_clamp`: saturate then round half away from zero (values ≥ 0)."""
    clipped = np.clip(values, 0.0, 255.0)
    return np.floor(clipped + 0.5).astype(np.uint8)


def _dart_round_scalar(v: float) -> int:
    if v <= 0:
        return 0
    if v >= 255:
        return 255
    return math.floor(v + 0.5)


def _distance_to_edge(edge: np.ndarray, width: int, height: int) -> np.ndarray:
    """Chamfer distance (5-7-11 metric, 1 and √2) to the nearest seam pixel."""
    distance = np.where(edge == 1, 0.0, 1e9).astype(np.float32)
    diagonal = np.float32(1.41421356237)
    columns = np.arange(width, dtype=np.float32)

    def horizontal_chain(row: np.ndarray, reverse: bool) -> np.ndarray:
        # d[i] = min(d[i], d[i±1] + 1) unrolls to a running min of
        # (a[k] − k) forward / (a[k] + k) backward. Tile longitude so a seam
        # on either side of the 0°/360° boundary is one pixel away.
        if width <= 1:
            return row
        row = np.concatenate((row, row, row))
        columns = np.arange(row.size, dtype=np.float32)
        if not reverse:
            shifted = row - columns
            np.minimum.accumulate(shifted, out=shifted)
            return (shifted + columns)[width : 2 * width]
        backward = row + columns
        backward = backward[::-1]
        np.minimum.accumulate(backward, out=backward)
        return (backward[::-1] - columns)[width : 2 * width]

    # Forward: left, up, and the two upper diagonals.
    for y in range(height):
        row_slice = slice(y * width, (y + 1) * width)
        row = distance[row_slice].copy()
        if y > 0:
            prev = distance[(y - 1) * width : y * width]
            row = np.minimum(row, prev + 1)
            row = np.minimum(row, np.roll(prev, 1) + diagonal)
            row = np.minimum(row, np.roll(prev, -1) + diagonal)
        distance[row_slice] = horizontal_chain(row, reverse=False)

    # Backward: right, down, and the two lower diagonals.
    for y in range(height - 1, -1, -1):
        row_slice = slice(y * width, (y + 1) * width)
        row = distance[row_slice].copy()
        if y + 1 < height:
            nxt = distance[(y + 1) * width : (y + 2) * width]
            row = np.minimum(row, nxt + 1)
            row = np.minimum(row, np.roll(nxt, 1) + diagonal)
            row = np.minimum(row, np.roll(nxt, -1) + diagonal)
        distance[row_slice] = horizontal_chain(row, reverse=True)

    return distance


def _neighbour_owned_by(
    owner: np.ndarray, width: int, height: int, other_frame: np.ndarray
) -> np.ndarray:
    """Vectorised ``_hasNeighbourOwnedBy``: a frame visible within 6 px across
    the same boundary, in 8 directions per distance."""
    n = width * height
    result = np.zeros(n, dtype=bool)
    if width <= 0 or height <= 0:
        return result
    padded = np.full((height + 12, width + 12), -1, dtype=np.int16)
    padded[6 : 6 + height] = np.pad(owner.reshape(height, width), ((0, 0), (6, 6)), mode="wrap")
    for distance in range(1, 7):
        for dy in (-distance, 0, distance):
            for dx in (-distance, 0, distance):
                if dx == 0 and dy == 0:
                    continue
                neighbour = padded[
                    6 + dy : 6 + dy + height, 6 + dx : 6 + dx + width
                ].reshape(-1)
                result |= neighbour == other_frame
    return result


def _write_best_only(
    output: np.ndarray,
    best_colour: np.ndarray,
    best_weight: np.ndarray,
    best_frame: np.ndarray,
    gains: np.ndarray,
    min_weight: float,
) -> None:
    n = len(best_weight)
    covered = best_weight > min_weight
    if not covered.any():
        return
    frames = np.where(best_frame < 0, 0, best_frame)
    colour = best_colour.reshape(n, 3).astype(np.float32)
    corrected = colour * gains[frames]
    output.reshape(n, 3)[covered] = _clamp_bytes(corrected[covered])


def _output_delta(output: np.ndarray, a: np.ndarray, b: np.ndarray) -> np.ndarray:
    rgb = output.reshape(-1, 3)
    return np.abs(rgb[a].astype(np.int16) - rgb[b].astype(np.int16)).mean(axis=1)



def composite_seams(
    *,
    output: np.ndarray,
    width: int,
    height: int,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_weight: np.ndarray,
    second_weight: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    channel_gains: list[float],
    min_weight: float,
    feather_px: int = SEAM_FEATHER_PX,
) -> "SeamBlendStats":
    n = width * height
    gains = np.asarray(channel_gains, dtype=np.float64).reshape(-1, 3)

    best_weight_f = best_weight.astype(np.float64)
    second_weight_f = second_weight.astype(np.float64)

    covered = (best_frame >= 0) & (best_weight_f > min_weight)
    overlap_mask = covered & (second_frame >= 0) & (second_weight_f > min_weight)
    overlap = int(overlap_mask.sum())

    if overlap == 0:
        _write_best_only(output, best_colour, best_weight_f, best_frame, gains, min_weight)
        if height == 0 or width == 0:
            wrap_only = 0.0
        else:
            first_col = np.arange(height) * width
            last_col = first_col + width - 1
            wrap_only = float(_output_delta(output, first_col, last_col).sum() / height)
        return SeamBlendStats(
            seam_pixels=0,
            flipped_pixels=0,
            overlap_pixels=0,
            ghost_energy=0.0,
            ghost_fraction=0.0,
            used_second_band=False,
            wrap_discontinuity=wrap_only,
        )

    label = np.zeros(n, dtype=np.uint8)
    # The two per-pixel cost maps are identical for the cut and for the
    # boundary polish, so they are measured once and shared. Building them
    # twice cost ~6 s per panorama on a 4096×2048 canvas.
    energy = build_seam_energy(
        width=width,
        height=height,
        best_colour=best_colour,
        second_colour=second_colour,
        best_frame=best_frame,
        second_frame=second_frame,
        channel_gains=gains,
    )
    cut = find_seam_labels(
        width=width,
        height=height,
        best_colour=best_colour,
        second_colour=second_colour,
        best_weight=best_weight,
        second_weight=second_weight,
        best_frame=best_frame,
        second_frame=second_frame,
        min_weight=min_weight,
        seam_cost_weight=SEAM_COST_WEIGHT,
        channel_gains=gains,
        energy=energy,
    )
    cut_used = cut is not None
    if cut is not None:
        label[:] = cut

    moved = refine_seams(
        label=label,
        width=width,
        height=height,
        best_weight=best_weight,
        second_weight=second_weight,
        best_colour=best_colour,
        second_colour=second_colour,
        best_frame=best_frame,
        second_frame=second_frame,
        min_weight=min_weight,
        channel_gains=gains,
        energy=energy,
    )

    smoothed_spikes = smooth_isolated_seam_spikes(
        label=label,
        width=width,
        height=height,
        best_frame=best_frame,
        second_frame=second_frame,
        best_weight=best_weight,
        second_weight=second_weight,
        best_colour=best_colour,
        second_colour=second_colour,
        min_weight=min_weight,
        channel_gains=gains,
    )

    # Ghost measurement on the colour-corrected contributors. Computed on the
    # overlap subset only: full-canvas float temporaries would cost hundreds of
    # megabytes at 4096-wide, which is exactly what the Dart budget avoided.
    bf = best_frame.astype(np.int64)
    sf = second_frame.astype(np.int64)
    bc = best_colour.reshape(n, 3)
    sc = second_colour.reshape(n, 3)

    diff_field = np.zeros(n, dtype=np.float64)
    overlap_idx = np.flatnonzero(overlap_mask)
    if len(overlap_idx) == 0:  # unreachable (overlap > 0) but keeps types honest
        ghost_energy = 0.0
        ghost_fraction = 0.0
    else:
        gained_best_overlap = bc[overlap_idx].astype(np.float64) * gains[bf[overlap_idx]]
        gained_second_overlap = sc[overlap_idx].astype(np.float64) * gains[sf[overlap_idx]]
        diff_values = np.abs(gained_best_overlap - gained_second_overlap).mean(axis=1)
        diff_field[overlap_idx] = diff_values
        diff_sum = float(diff_values.sum())
        visible = int((diff_values > GHOST_VISIBLE_DELTA).sum())
        ghost_energy = diff_sum / len(overlap_idx)
        ghost_fraction = visible / len(overlap_idx)

    # Ownership map: which physical frame renders each pixel.
    owner = np.full(n, -1, dtype=np.int16)
    use_second = overlap_mask & (label == 1)
    owner[covered] = np.where(use_second[covered], sf[covered], bf[covered]).astype(np.int16)

    grid = owner.reshape(height, width)
    right = np.roll(grid, -1, axis=1)
    horizontal = (grid >= 0) & (right >= 0) & (grid != right)
    edge_grid = horizontal | np.roll(horizontal, 1, axis=1)
    vertical = (grid[1:] >= 0) & (grid[:-1] >= 0) & (grid[1:] != grid[:-1])
    edge_grid[1:] |= vertical
    edge_grid[:-1] |= vertical
    edge = edge_grid.astype(np.uint8).reshape(-1)
    seam_pixels = int(edge.sum())

    seam_distance = _distance_to_edge(edge, width, height)

    other_frame = np.where(label == 1, bf, sf)
    has_neighbour = _neighbour_owned_by(owner, width, height, other_frame)
    band = float(feather_px)
    sd_overlap = seam_distance[overlap_idx]
    can_feather_overlap = (
        (sd_overlap < band)
        & (diff_field[overlap_idx] <= GHOST_VISIBLE_DELTA)
        & has_neighbour[overlap_idx]
    )
    ratio = _seam_gaussian(sd_overlap / band) / _seam_gaussian(1.0)
    w_own = np.where(
        can_feather_overlap, 0.5 + 0.5 * np.clip(ratio, 0.0, 1.0), 1.0
    )

    out_grid = output.reshape(n, 3)
    straight_idx = np.flatnonzero(covered & ~overlap_mask)
    if len(straight_idx):
        straight_corrected = (
            bc[straight_idx].astype(np.float64) * gains[bf[straight_idx]]
        )
        out_grid[straight_idx] = _clamp_bytes(straight_corrected)

    if len(overlap_idx):
        own_second_sub = label[overlap_idx] == 1
        own_value = np.where(own_second_sub[:, None], gained_second_overlap, gained_best_overlap)
        other_value = np.where(own_second_sub[:, None], gained_best_overlap, gained_second_overlap)
        blended = own_value * w_own[:, None] + other_value * (1.0 - w_own[:, None])
        out_grid[overlap_idx] = _clamp_bytes(blended)

    # Seam and wraparound quality, measured on the composited output.
    owner_here = np.where(label == 0, bf, sf).reshape(height, width)
    previous_owner = np.roll(owner_here, 1, axis=1)
    seam_change = (
        (owner_here >= 0)
        & (previous_owner >= 0)
        & (owner_here != previous_owner)
    )
    if seam_change.any():
        idx_a = np.flatnonzero(seam_change.reshape(-1))
        rows = idx_a // width
        cols = idx_a % width
        idx_b = rows * width + ((cols - 1) % width)
        seam_discontinuity = float(_output_delta(output, idx_a, idx_b).sum() / len(idx_a))
    else:
        seam_discontinuity = 0.0

    if height > 0:
        first_col = np.arange(height) * width
        last_col = first_col + width - 1
        wrap_sum = float(_output_delta(output, first_col, last_col).sum())
        wrap_discontinuity = wrap_sum / height
    else:
        wrap_discontinuity = 0.0

    return SeamBlendStats(
        seam_pixels=seam_pixels,
        flipped_pixels=moved + smoothed_spikes,
        overlap_pixels=overlap,
        ghost_energy=ghost_energy,
        ghost_fraction=ghost_fraction,
        used_second_band=True,
        seam_discontinuity=seam_discontinuity,
        wrap_discontinuity=wrap_discontinuity,
        cut_used=cut_used,
    )


class SeamBlendStats:
    def __init__(
        self,
        *,
        seam_pixels: int,
        flipped_pixels: int,
        overlap_pixels: int,
        ghost_energy: float,
        ghost_fraction: float,
        used_second_band: bool,
        seam_discontinuity: float = 0.0,
        wrap_discontinuity: float = 0.0,
        cut_used: bool = False,
    ):
        self.seam_pixels = seam_pixels
        self.flipped_pixels = flipped_pixels
        self.overlap_pixels = overlap_pixels
        self.ghost_energy = ghost_energy
        self.ghost_fraction = ghost_fraction
        self.used_second_band = used_second_band
        self.seam_discontinuity = seam_discontinuity
        self.wrap_discontinuity = wrap_discontinuity
        self.cut_used = cut_used

    def to_json(self) -> dict:
        return {
            "seamPixels": self.seam_pixels,
            "seamPixelsMoved": self.flipped_pixels,
            "overlapPixels": self.overlap_pixels,
            "ghostEnergy": round(self.ghost_energy, 2),
            "ghostFraction": round(self.ghost_fraction, 4),
            "multiBand": self.used_second_band,
            "seamDiscontinuity": round(self.seam_discontinuity, 2),
            "wrapDiscontinuity": round(self.wrap_discontinuity, 2),
            "graphCut": self.cut_used,
        }


def refine_seams(
    *,
    label: np.ndarray,
    width: int,
    height: int,
    best_weight: np.ndarray,
    second_weight: np.ndarray,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    min_weight: float,
    channel_gains: np.ndarray | None = None,
    energy: SeamEnergyMaps | None = None,
) -> int:
    """Moves ownership boundaries to where the two frames agree better."""
    moved = 0
    bf = best_frame
    sf = second_frame
    bw = best_weight
    sw = second_weight
    # The seam cost is the same for every candidate shift, so it is measured
    # once for the canvas instead of once per probe. This was the second
    # largest cost in the stitch: ~450 000 scalar cost evaluations, each
    # re-deriving eight neighbour luminances in Python. The caller can hand in
    # the maps it already built for the cut, so the canvas is measured once.
    maps = energy
    if maps is None:
        maps = build_seam_energy(
            width=width,
            height=height,
            best_colour=best_colour,
            second_colour=second_colour,
            best_frame=bf,
            second_frame=sf,
            channel_gains=channel_gains,
        )
    for y in range(height):
        row = y * width
        # Only positions where the owner actually changes can host a boundary.
        # Scanning all `width` pixels per row in Python cost more than the
        # shifts themselves.
        start = 0
        while True:
            owners, prev_owners, candidates = _row_boundaries(
                label=label,
                row=row,
                width=width,
                best_frame=bf,
                second_frame=sf,
                second_weight=sw,
                min_weight=min_weight,
            )
            positions = np.nonzero(candidates)[0]
            positions = positions[positions >= start]
            if positions.size == 0:
                break
            shifted = False
            for x in positions:
                x = int(x)
                step = _try_shift_boundary(
                    label=label,
                    width=width,
                    height=height,
                    row_start=row,
                    boundary=x,
                    left_owner=int(prev_owners[x]),
                    right_owner=int(owners[x]),
                    min_weight=min_weight,
                    best_frame=bf,
                    second_frame=sf,
                    best_weight=bw,
                    second_weight=sw,
                    best_colour=best_colour,
                    second_colour=second_colour,
                    channel_gains=channel_gains,
                    maps=maps,
                )
                if step:
                    moved += step
                    # The shift rewrote this row's labels, so the remaining
                    # candidates are re-derived from the row's new state — the
                    # sequential semantics of the original loop.
                    start = x + 1
                    shifted = True
                    break
            if not shifted:
                break
    return moved


def _row_boundaries(
    *,
    label: np.ndarray,
    row: int,
    width: int,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    second_weight: np.ndarray,
    min_weight: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Owner, previous owner and "is a boundary" for one row."""
    labels = label[row : row + width]
    owners = np.where(labels == 0, best_frame[row : row + width], second_frame[row : row + width])
    prev_owners = np.roll(owners, 1)
    weights = second_weight[row : row + width]
    prev_weights = np.roll(weights, 1)
    candidates = (
        (owners >= 0)
        & (prev_owners >= 0)
        & (owners != prev_owners)
        & (prev_weights > min_weight)
        & (weights > min_weight)
    )
    return owners, prev_owners, candidates


def _try_shift_boundary(
    *,
    label: np.ndarray,
    width: int,
    height: int,
    row_start: int,
    boundary: int,
    left_owner: int,
    right_owner: int,
    min_weight: float,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    best_weight: np.ndarray,
    second_weight: np.ndarray,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    channel_gains: np.ndarray | None,
    maps: SeamEnergyMaps | None = None,
) -> int:
    def owner_at(i: int) -> int:
        return int(best_frame[i] if label[i] == 0 else second_frame[i])

    def supports(i: int, frame: int) -> bool:
        if best_frame[i] == frame and best_weight[i] > min_weight:
            return True
        if second_frame[i] == frame and second_weight[i] > min_weight:
            return True
        return False

    def seam_cost_at(position: int) -> float:
        i = row_start + (position % width)
        cost = seam_pixel_cost_at(
            best_colour=best_colour,
            second_colour=second_colour,
            best_frame=best_frame,
            second_frame=second_frame,
            width=width,
            height=height,
            index=i,
            channel_gains=channel_gains,
            maps=maps,
        )
        return SEAM_COST_WEIGHT * cost / 255.0

    current = seam_cost_at(boundary)
    best_cost = current
    best_shift = 0

    for shift in range(-SEAM_SEARCH_RADIUS, SEAM_SEARCH_RADIUS + 1):
        if shift == 0 or abs(shift) >= width:
            continue
        target = boundary + shift
        target_x = target % width
        wanted_owner = left_owner if shift > 0 else right_owner
        displaced_owner = right_owner if shift > 0 else left_owner
        blocked = not supports(
            row_start + ((target_x - 1) % width), left_owner
        ) or not supports(row_start + target_x, right_owner)
        sampling = 0.0
        crossed = (
            [(boundary + offset) % width for offset in range(shift)]
            if shift > 0
            else [(boundary + shift + offset) % width for offset in range(-shift)]
        )
        for p in crossed:
            if blocked:
                break
            i = row_start + p
            if owner_at(i) != displaced_owner or not supports(i, wanted_owner):
                blocked = True
                break
            sampling += abs(
                math.log(best_weight[i] + 1e-6) - math.log(second_weight[i] + 1e-6)
            )
        if blocked:
            continue

        seam = seam_cost_at(target)
        cost = seam + sampling
        if cost < best_cost - 1e-6:
            best_cost = cost
            best_shift = shift

    if best_shift == 0:
        return 0

    crossed = (
        [(boundary + offset) % width for offset in range(best_shift)]
        if best_shift > 0
        else [(boundary + best_shift + offset) % width for offset in range(-best_shift)]
    )
    assigned_owner = left_owner if best_shift > 0 else right_owner
    for p in crossed:
        i = row_start + p
        if best_frame[i] == assigned_owner and best_weight[i] > min_weight:
            label[i] = 0
        elif second_frame[i] == assigned_owner and second_weight[i] > min_weight:
            label[i] = 1
    return len(crossed)


def smooth_isolated_seam_spikes(
    *,
    label: np.ndarray,
    width: int,
    height: int,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    best_weight: np.ndarray,
    second_weight: np.ndarray,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    min_weight: float,
    channel_gains: np.ndarray | None = None,
) -> int:
    """Removes only isolated, low-difference ownership spikes."""
    if width < 3 or height < 3:
        return 0
    n = width * height
    grid = label.reshape(height, width)
    bf_grid = best_frame.reshape(height, width)
    sf_grid = second_frame.reshape(height, width)
    bw_grid = best_weight.reshape(height, width)
    sw_grid = second_weight.reshape(height, width)

    best_valid = (bf_grid >= 0) & (bw_grid > min_weight)
    owner = np.where(
        (grid == 1) & (sf_grid >= 0) & (sw_grid > min_weight) & best_valid,
        sf_grid,
        np.where(best_valid, bf_grid, -1),
    )

    candidate = (
        (sf_grid >= 0)
        & (sw_grid > min_weight)
        & (bf_grid >= 0)
        & (bw_grid > min_weight)
        & (bf_grid != sf_grid)
    )
    current = owner
    alternative = np.where(grid == 0, sf_grid, bf_grid)
    differs = current != alternative

    alt_count = np.zeros((height, width), dtype=np.int32)
    for shift, axis in ((-1, 1), (1, 1), (-1, 0), (1, 0)):
        shifted = np.full((height, width), -1, dtype=np.int64)
        if axis == 1:
            shifted = np.roll(owner, -shift, axis=1)
        else:
            if shift < 0:
                shifted[:-1, :] = owner[1:, :]
            else:
                shifted[1:, :] = owner[:-1, :]
        alt_count += (shifted == alternative).astype(np.int32)

    low_difference = np.zeros(n, dtype=bool)
    candidate_indices = np.flatnonzero(candidate.reshape(-1))
    best_pixels = best_colour.reshape(n, 3)
    second_pixels = second_colour.reshape(n, 3)
    gains = (
        np.asarray(channel_gains, dtype=np.float32).reshape(-1, 3)
        if channel_gains is not None
        else None
    )
    chunk_size = 262144
    for start in range(0, len(candidate_indices), chunk_size):
        indices = candidate_indices[start : start + chunk_size]
        best_values = best_pixels[indices].astype(np.float32)
        second_values = second_pixels[indices].astype(np.float32)
        if gains is not None:
            best_values *= gains[bf_grid.reshape(-1)[indices]]
            second_values *= gains[sf_grid.reshape(-1)[indices]]
        low_difference[indices] = (
            np.abs(best_values - second_values).mean(axis=1)
            <= GHOST_VISIBLE_DELTA
        )

    flip = (
        candidate
        & differs
        & (alt_count >= 3)
        & low_difference.reshape(height, width)
    )
    flip[0, :] = False
    flip[-1, :] = False

    changed = int(flip.sum())
    if changed:
        grid[flip] = np.where(grid[flip] == 0, 1, 0).astype(np.uint8)
    return changed
