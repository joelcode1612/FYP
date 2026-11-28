"""Graph-cut seam ownership for the equirectangular canvas.

Faithful port of ``lib/features/sphere_capture/domain/graph_cut_seams.dart``.

Ownership is a binary submodular energy, so the global optimum is a minimum
s-t cut. The cut runs on a 4×-reduced grid to keep the residual graph
resident, and the labelling is upsampled; ``seam_blend`` recovers pixel
precision afterwards. Exceeding the node budget returns ``None`` and the
caller keeps its weight-derived labelling — a degradation, never a failure.
"""

from __future__ import annotations

import math

import numpy as np

SEAM_CUT_SCALE = 4
SEAM_CUT_MAX_NODES = 600000
_FLOW_EPSILON = 1e-12


def seam_cut_graph_bytes(width: int, height: int, scale: int = SEAM_CUT_SCALE) -> int:
    """Approximate resident bytes the cut graph needs; 0 means "too big"."""
    gw = (width + scale - 1) // scale
    gh = (height + scale - 1) // scale
    cells = gw * gh
    if cells > SEAM_CUT_MAX_NODES:
        return 0
    edges = cells * 12 + 16
    return edges * 16 + (cells + 2) * 16


def _gains_for(channel_gains: np.ndarray | None, frame_id: int) -> np.ndarray:
    if channel_gains is None or frame_id < 0 or frame_id >= len(channel_gains):
        return np.ones(3, dtype=np.float32)
    return channel_gains[frame_id]


def _gain_rows(channel_gains: np.ndarray | None, frame_ids: np.ndarray) -> np.ndarray:
    """Per-pixel channel gains, shaped ``(n, 3)``.

    The scalar :func:`_gains_for` returns ones for a pixel with no contributing
    frame, for an out-of-range id, and when the caller supplied no gains at
    all. The vectorised form has to reproduce all three cases exactly, because
    these weights are summed over hundreds of thousands of pixels.
    """
    ids = np.asarray(frame_ids, dtype=np.int64).ravel()
    rows = np.ones((ids.shape[0], 3), dtype=np.float32)
    if channel_gains is None or len(channel_gains) == 0:
        return rows
    valid = (ids >= 0) & (ids < len(channel_gains))
    if valid.any():
        rows[valid] = np.asarray(channel_gains, dtype=np.float32)[ids[valid]]
    return rows


class SeamEnergyMaps:
    """The two per-pixel seam costs, computed once for the whole canvas.

    The scalar helpers below are called hundreds of thousands of times per
    panorama, and each call re-derived the same eight neighbour luminances in
    Python. On a 4096×2048 canvas that was 15 million interpreted lookups —
    more than half the stitching time. These maps hold exactly the same
    numbers, computed with NumPy.
    """

    __slots__ = ("delta", "edge")

    def __init__(self, delta: np.ndarray, edge: np.ndarray) -> None:
        self.delta = delta
        self.edge = edge

    def pixel_cost(self, index: int) -> float:
        return float(self.delta[index]) + 6.0 * float(self.edge[index])


def build_seam_energy(
    *,
    width: int,
    height: int,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    channel_gains: np.ndarray | None = None,
) -> SeamEnergyMaps:
    """Per-pixel colour difference and Sobel edge energy.

    ``delta`` is :func:`_delta` for every pixel; ``edge`` is
    :func:`seam_sobel_edge_energy_at` for every pixel. Both are float32, one
    value per pixel, so the caller can index them directly.
    """
    count = width * height
    best_rgb = np.asarray(best_colour, dtype=np.float32).reshape(count, 3)
    second_rgb = np.asarray(second_colour, dtype=np.float32).reshape(count, 3)
    best_gain = _gain_rows(channel_gains, best_frame)
    second_gain = _gain_rows(channel_gains, second_frame)

    delta = np.abs(best_rgb * best_gain - second_rgb * second_gain).sum(axis=1) / 3.0
    edge = _sobel_map(best_rgb, best_gain, best_frame, width, height)
    edge += _sobel_map(second_rgb, second_gain, second_frame, width, height)
    return SeamEnergyMaps(delta.astype(np.float32), edge.astype(np.float32))


_LUMA_WEIGHTS = np.array([0.299, 0.587, 0.114], dtype=np.float32)
#: Rows per block when building the Sobel map. The full canvas would need
#: ~250 MB of temporaries at 4096×2048; blocking keeps it near 20 MB.
_SOBEL_ROW_BLOCK = 128


def _sobel_map(
    rgb: np.ndarray,
    gains: np.ndarray,
    frame_ids: np.ndarray,
    width: int,
    height: int,
) -> np.ndarray:
    """The scalar Sobel response for every pixel, in one pass.

    Mirrors :func:`_sobel_at` exactly: neighbours that belong to another frame
    (or fall outside the canvas) are replaced by the centre pixel's luminance,
    so a frame's own edges never borrow contrast from its neighbour.
    """
    luma = (rgb * gains * _LUMA_WEIGHTS).sum(axis=1).astype(np.float32)
    luma = luma.reshape(height, width)
    ids = np.asarray(frame_ids, dtype=np.int64).ravel().reshape(height, width)
    out = np.zeros((height, width), dtype=np.float32)
    if height < 1 or width < 1:
        return out.ravel()

    for block_start in range(0, height, _SOBEL_ROW_BLOCK):
        block_end = min(height, block_start + _SOBEL_ROW_BLOCK)
        centre = luma[block_start:block_end]
        centre_ids = ids[block_start:block_end]

        def sample(dy: int, dx: int) -> np.ndarray:
            # A neighbour outside the canvas is the centre pixel's own value,
            # exactly as the scalar helper returns. Replicating the border
            # would not do: for a pixel on the top row the *diagonal* upper
            # neighbours would then read their in-row neighbours instead of
            # themselves.
            values = centre.copy()
            neighbour_ids = centre_ids.copy()
            row_lo = max(block_start, -dy)
            row_hi = min(block_end, height - dy)
            col_lo = max(0, -dx)
            col_hi = min(width, width - dx)
            if row_lo < row_hi and col_lo < col_hi:
                values[row_lo - block_start : row_hi - block_start, col_lo:col_hi] = (
                    luma[row_lo + dy : row_hi + dy, col_lo + dx : col_hi + dx]
                )
                neighbour_ids[
                    row_lo - block_start : row_hi - block_start, col_lo:col_hi
                ] = ids[row_lo + dy : row_hi + dy, col_lo + dx : col_hi + dx]
            same = (neighbour_ids == centre_ids) & (centre_ids >= 0)
            return np.where(same, values, centre)

        tl = sample(-1, -1)
        top = sample(0, -1)
        tr = sample(1, -1)
        left = sample(-1, 0)
        right = sample(1, 0)
        bl = sample(-1, 1)
        bottom = sample(0, 1)
        br = sample(1, 1)
        gx = (-tl - 2 * left - bl + tr + 2 * right + br) / 4.0
        gy = (-tl - 2 * top - tr + bl + 2 * bottom + br) / 4.0
        magnitude = np.sqrt(gx * gx + gy * gy)
        np.clip(magnitude, 0.0, 255.0, out=magnitude)
        magnitude[centre_ids < 0] = 0.0
        out[block_start:block_end] = magnitude
    return out.ravel()


def _delta(
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    i: int,
    channel_gains: np.ndarray | None,
) -> float:
    o = i * 3
    best_gain = _gains_for(channel_gains, int(best_frame[i]))
    second_gain = _gains_for(channel_gains, int(second_frame[i]))
    return (
        abs(float(best_colour[o]) * float(best_gain[0]) - float(second_colour[o]) * float(second_gain[0]))
        + abs(float(best_colour[o + 1]) * float(best_gain[1]) - float(second_colour[o + 1]) * float(second_gain[1]))
        + abs(float(best_colour[o + 2]) * float(best_gain[2]) - float(second_colour[o + 2]) * float(second_gain[2]))
    ) / 3.0


def _luma(rgb: np.ndarray, i: int, gain: np.ndarray) -> float:
    off = i * 3
    return (
        rgb[off] * gain[0] * 0.299
        + rgb[off + 1] * gain[1] * 0.587
        + rgb[off + 2] * gain[2] * 0.114
    )


def seam_sobel_edge_energy_at(
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    width: int,
    height: int,
    index: int,
    channel_gains: np.ndarray | None = None,
) -> float:
    return _sobel_at(best_colour, best_frame, width, height, index, channel_gains) + _sobel_at(
        second_colour, second_frame, width, height, index, channel_gains
    )


def seam_pixel_cost_at(
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    width: int,
    height: int,
    index: int,
    channel_gains: np.ndarray | None = None,
    maps: SeamEnergyMaps | None = None,
) -> float:
    if maps is not None:
        return maps.pixel_cost(index)
    return _delta(
        best_colour, second_colour, best_frame, second_frame, index, channel_gains
    ) + 6.0 * seam_sobel_edge_energy_at(
        best_colour=best_colour,
        second_colour=second_colour,
        best_frame=best_frame,
        second_frame=second_frame,
        width=width,
        height=height,
        index=index,
        channel_gains=channel_gains,
    )


def _sobel_at(
    rgb: np.ndarray,
    frame_ids: np.ndarray,
    width: int,
    height: int,
    index: int,
    channel_gains: np.ndarray | None,
) -> float:
    x = index % width
    y = index // width
    frame_id = frame_ids[index]
    if frame_id < 0:
        return 0.0
    gain = _gains_for(channel_gains, int(frame_id))
    centre = _luma(rgb, index, gain)

    def sample(dx: int, dy: int) -> float:
        xx = x + dx
        yy = y + dy
        if xx < 0 or xx >= width or yy < 0 or yy >= height:
            return centre
        j = yy * width + xx
        if frame_ids[j] != frame_id:
            return centre
        return _luma(rgb, j, gain)

    tl = sample(-1, -1)
    t = sample(0, -1)
    tr = sample(1, -1)
    l = sample(-1, 0)
    r = sample(1, 0)
    bl = sample(-1, 1)
    b = sample(0, 1)
    br = sample(1, 1)
    # Normalise the usual Sobel response by 4 so a maximum-contrast step has
    # roughly 255 units of energy.
    dx = (-tl - 2 * l - bl + tr + 2 * r + br) / 4
    dy = (-tl - 2 * t - tr + bl + 2 * b + br) / 4
    return float(min(255.0, max(0.0, math.sqrt(dx * dx + dy * dy))))


def _dinic(
    node_count: int,
    s: int,
    t: int,
    head: np.ndarray,
    to: np.ndarray,
    nxt: np.ndarray,
    capacity: np.ndarray,
) -> None:
    level = np.full(node_count, -1, dtype=np.int64)
    iter_ = np.empty(node_count, dtype=np.int64)
    queue = np.empty(node_count, dtype=np.int64)
    inf = 1e18

    def bfs() -> bool:
        level.fill(-1)
        qh = 0
        qt = 0
        level[s] = 0
        queue[qt] = s
        qt += 1
        while qh < qt:
            u = int(queue[qh])
            qh += 1
            e = head[u]
            while e != -1:
                if capacity[e] > _FLOW_EPSILON:
                    v = to[e]
                    if level[v] == -1:
                        level[v] = level[u] + 1
                        queue[qt] = v
                        qt += 1
                e = nxt[e]
        return level[t] != -1

    # Iterative DFS replicating the Dart recursion exactly: on a dead end the
    # parent resumes from the edge after the one that failed (current-arc).
    def dfs_one() -> float:
        # (node, edge descended through, flow available at the node)
        stack: list[tuple[int, int, float]] = []
        u = s
        pushed = inf
        while True:
            if u == t:
                flow = pushed
                for parent, edge, _available in stack:
                    capacity[edge] -= flow
                    capacity[edge ^ 1] += flow
                return flow
            e = int(iter_[u])
            descended = False
            while e != -1:
                iter_[u] = e
                v = to[e]
                if capacity[e] > _FLOW_EPSILON and level[v] == level[u] + 1:
                    stack.append((u, e, pushed))
                    cap = float(capacity[e])
                    pushed = pushed if pushed < cap else cap
                    u = int(v)
                    descended = True
                    break
                e = nxt[e]
            if descended:
                continue
            iter_[u] = -1
            if not stack:
                return 0.0
            parent, edge, parent_pushed = stack.pop()
            u = parent
            pushed = parent_pushed
            iter_[u] = nxt[edge]

    while bfs():
        iter_[:] = head
        while True:
            flow = dfs_one()
            if flow <= _FLOW_EPSILON:
                break


def find_seam_labels(
    *,
    width: int,
    height: int,
    best_colour: np.ndarray,
    second_colour: np.ndarray,
    best_weight: np.ndarray,
    second_weight: np.ndarray,
    best_frame: np.ndarray,
    second_frame: np.ndarray,
    min_weight: float,
    seam_cost_weight: float,
    scale: int = SEAM_CUT_SCALE,
    channel_gains: np.ndarray | None = None,
    energy: SeamEnergyMaps | None = None,
) -> np.ndarray | None:
    """Runs the min-cut and returns a full-resolution ownership label map.

    ``0`` means "the best contributor owns this pixel", ``1`` means "the second
    contributor does". Returns ``None`` when the graph would exceed the node
    budget; the caller then keeps its weight-derived labels.
    """
    if width < 2 or height < 2:
        return None
    gw = (width + scale - 1) // scale
    gh = (height + scale - 1) // scale
    cells = gw * gh
    if cells > SEAM_CUT_MAX_NODES:
        return None

    node_count = cells + 2
    s = cells
    t = cells + 1

    data_best = np.zeros(cells, dtype=np.float64)
    data_second = np.zeros(cells, dtype=np.float64)
    delta_sum = np.zeros(cells, dtype=np.float64)
    active = np.zeros(cells, dtype=np.uint8)

    best_weight_list = best_weight
    second_weight_list = second_weight
    best_frame_list = best_frame
    second_frame_list = second_frame

    # One vectorised pass over the canvas, then a blocked reduction into the
    # cell grid. The per-cell Python loop this replaces summed five values for
    # every one of ~8 million pixels and re-derived the Sobel response for each
    # cell centre — the largest single cost in the whole stitch.
    if energy is None:
        energy = build_seam_energy(
            width=width,
            height=height,
            best_colour=best_colour,
            second_colour=second_colour,
            best_frame=best_frame_list,
            second_frame=second_frame_list,
            channel_gains=channel_gains,
        )
    best_w = np.asarray(best_weight_list, dtype=np.float64).ravel()
    second_w = np.asarray(second_weight_list, dtype=np.float64).ravel()
    pixel_active = (second_w > min_weight) & (
        np.asarray(second_frame_list).ravel() >= 0
    )
    counted = pixel_active.astype(np.float64)
    cost_best_px = np.where(pixel_active, -np.log(best_w + 1e-6), 0.0)
    cost_second_px = np.where(pixel_active, -np.log(second_w + 1e-6), 0.0)
    delta_px = np.where(pixel_active, energy.delta, 0.0).astype(np.float64)

    padded_h = gh * scale
    padded_w = gw * scale

    def reduce_to_cells(values: np.ndarray) -> np.ndarray:
        block = np.zeros((padded_h, padded_w), dtype=np.float64)
        block[:height, :width] = np.asarray(values, dtype=np.float64).reshape(
            height, width
        )
        return block.reshape(gh, scale, gw, scale).sum(axis=(1, 3))

    count_cells = reduce_to_cells(np.ones(width * height, dtype=np.float64))
    active_cells = reduce_to_cells(counted)
    best_cost_cells = reduce_to_cells(cost_best_px)
    second_cost_cells = reduce_to_cells(cost_second_px)
    delta_cells = reduce_to_cells(delta_px)

    # The cell's representative pixel for the edge term: the centre when it is
    # active, otherwise the first active pixel in raster order.
    active_block = np.zeros((padded_h, padded_w), dtype=bool)
    active_block[:height, :width] = pixel_active.reshape(height, width)
    ordered = (
        active_block.reshape(gh, scale, gw, scale)
        .transpose(0, 2, 1, 3)
        .reshape(gh, gw, scale * scale)
    )
    has_active = ordered.any(axis=2)
    first = ordered.argmax(axis=2)
    first_row = first // scale
    first_col = first % scale
    fallback_index = (np.arange(gh)[:, None] * scale + first_row) * width + (
        np.arange(gw)[None, :] * scale + first_col
    )
    # The centre pixel is preferred when it is active — the same choice the
    # scalar loop made before falling back to the first active pixel.
    centre_y = np.minimum(
        height - 1, np.arange(gh)[:, None] * scale + scale // 2
    )
    centre_x = np.minimum(
        width - 1, np.arange(gw)[None, :] * scale + scale // 2
    )
    centre_index = centre_y * width + centre_x
    centre_active = pixel_active.reshape(height, width)[centre_y, centre_x]
    sample_index = np.where(centre_active, centre_index, fallback_index)
    sample_index = np.where(has_active, sample_index, -1)
    edge_energy = np.where(
        has_active,
        energy.edge[np.maximum(sample_index, 0)],
        0.0,
    ).astype(np.float64)

    populated = count_cells > 0
    usable = populated & (active_cells > 0)
    safe_active = np.where(active_cells > 0, active_cells, 1.0)
    # Flat, cell-major order — the edge builder indexes these by `cell`.
    data_best = np.where(usable, best_cost_cells / safe_active, 0.0).ravel()
    data_second = np.where(
        usable,
        second_cost_cells / safe_active,
        np.where(populated, np.inf, 0.0),
    ).ravel()
    delta_sum = np.where(
        usable, delta_cells / safe_active + 6.0 * edge_energy, 0.0
    ).ravel()
    active = usable.astype(np.uint8).ravel()

    max_edges = cells * 12 + 16
    edge_capacity = np.zeros(max_edges, dtype=np.float64)
    edge_to = np.zeros(max_edges, dtype=np.int64)
    edge_next = np.zeros(max_edges, dtype=np.int64)
    edge_count = 0
    head = np.full(node_count, -1, dtype=np.int64)

    def add_edge(u: int, v: int, capacity: float) -> None:
        nonlocal edge_count
        edge_to[edge_count] = v
        edge_capacity[edge_count] = capacity
        edge_next[edge_count] = head[u]
        head[u] = edge_count
        edge_count += 1

        edge_to[edge_count] = u
        edge_capacity[edge_count] = 0.0
        edge_next[edge_count] = head[v]
        head[v] = edge_count
        edge_count += 1

    for gy in range(gh):
        for gx in range(gw):
            cell = gy * gw + gx
            if active[cell] == 0:
                add_edge(s, cell, 1e9)
                add_edge(cell, t, 0.0)
                continue
            add_edge(s, cell, float(data_second[cell]))
            add_edge(cell, t, float(data_best[cell]))

            if gx + 1 < gw:
                other = cell + 1
                if active[other] == 1:
                    cap = (
                        seam_cost_weight
                        * (float(delta_sum[cell]) + float(delta_sum[other]))
                        / 2
                        / 255.0
                    )
                    add_edge(cell, other, cap)
                    add_edge(other, cell, cap)
            # Longitude is periodic. Without this edge the cut is optimized
            # on a rectangle and may place an unconstrained seam at 0°/360°.
            if gx == gw - 1 and gw > 1:
                other = gy * gw
                if active[other] == 1:
                    cap = (
                        seam_cost_weight
                        * (float(delta_sum[cell]) + float(delta_sum[other]))
                        / 2
                        / 255.0
                    )
                    add_edge(cell, other, cap)
                    add_edge(other, cell, cap)
            if gy + 1 < gh:
                other = cell + gw
                if active[other] == 1:
                    cap = (
                        seam_cost_weight
                        * (float(delta_sum[cell]) + float(delta_sum[other]))
                        / 2
                        / 255.0
                    )
                    add_edge(cell, other, cap)
                    add_edge(other, cell, cap)

    _dinic(node_count, s, t, head, edge_to, edge_next, edge_capacity)

    level = np.full(node_count, -1, dtype=np.int64)
    queue = np.empty(node_count, dtype=np.int64)
    qh = 0
    qt = 0
    level[s] = 0
    queue[qt] = s
    qt += 1
    while qh < qt:
        u = int(queue[qh])
        qh += 1
        e = head[u]
        while e != -1:
            if edge_capacity[e] > _FLOW_EPSILON:
                v = edge_to[e]
                if level[v] == -1:
                    level[v] = level[u] + 1
                    queue[qt] = v
                    qt += 1
            e = edge_next[e]

    labels = np.zeros(width * height, dtype=np.uint8)
    for gy in range(gh):
        y1 = min(height, (gy + 1) * scale)
        for gx in range(gw):
            cell = gy * gw + gx
            # Unreachable from the source → sink side → "second".
            if level[cell] != -1:
                continue
            x1 = min(width, (gx + 1) * scale)
            for y in range(gy * scale, y1):
                row = y * width
                for x in range(gx * scale, x1):
                    i = row + x
                    if second_weight_list[i] <= min_weight or second_frame_list[i] < 0:
                        continue
                    labels[i] = 1
    return labels
