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
) -> float:
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

    for gy in range(gh):
        for gx in range(gw):
            cell = gy * gw + gx
            count = 0
            active_count = 0
            best_cost = 0.0
            second_cost = 0.0
            delta = 0.0
            y1 = min(height, (gy + 1) * scale)
            x1 = min(width, (gx + 1) * scale)
            for y in range(gy * scale, y1):
                row = y * width
                for x in range(gx * scale, x1):
                    i = row + x
                    count += 1
                    if second_weight_list[i] <= min_weight or second_frame_list[i] < 0:
                        continue
                    active_count += 1
                    best_cost += -math.log(best_weight_list[i] + 1e-6)
                    second_cost += -math.log(second_weight_list[i] + 1e-6)
                    delta += _delta(
                        best_colour,
                        second_colour,
                        best_frame_list,
                        second_frame_list,
                        i,
                        channel_gains,
                    )
            if count == 0:
                continue
            if active_count == 0:
                data_best[cell] = 0.0
                data_second[cell] = math.inf
                active[cell] = 0
                continue
            data_best[cell] = best_cost / active_count
            data_second[cell] = second_cost / active_count

            centre_x = min(width - 1, gx * scale + scale // 2)
            centre_y = min(height - 1, gy * scale + scale // 2)
            sample_index = centre_y * width + centre_x
            if (
                second_frame_list[sample_index] < 0
                or second_weight_list[sample_index] <= min_weight
            ):
                sample_index = -1
                for yy in range(gy * scale, y1):
                    if sample_index >= 0:
                        break
                    for xx in range(gx * scale, x1):
                        candidate = yy * width + xx
                        if (
                            second_frame_list[candidate] >= 0
                            and second_weight_list[candidate] > min_weight
                        ):
                            sample_index = candidate
                            break
            edge_energy = (
                0.0
                if sample_index < 0
                else seam_sobel_edge_energy_at(
                    best_colour=best_colour,
                    second_colour=second_colour,
                    best_frame=best_frame,
                    second_frame=second_frame,
                    width=width,
                    height=height,
                    index=sample_index,
                    channel_gains=channel_gains,
                )
            )
            color_diff = delta / active_count
            delta_sum[cell] = color_diff + 6.0 * edge_energy
            active[cell] = 1

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
