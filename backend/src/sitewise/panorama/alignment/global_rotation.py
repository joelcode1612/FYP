"""Robust joint optimisation of every camera rotation in one solution.

## Why a joint solve

Refining each frame against its neighbours independently accumulates error
around the horizon: frame 1 is adjusted against frame 2, frame 2 against frame
3, and by the time the ring closes, frame 1 and frame 44 disagree by several
degrees. That is what produces a visible step at the 0°/360° seam and a band of
tearing where the upper ring meets the middle ring.

Solving all rotations at once — a rotation-only bundle adjustment — lets the
loop closure constrain the whole ring instead of just its ends. Every
photograph participates in the same solution, so a polar cap cannot drift away
from the upper ring it overlaps.

## The model

* **Edge residual** — for a verified pair ``(a, b)`` with measured relative
  rotation ``R_rel = R_b⁻¹ R_a``, the error is ``log( (R_b⁻¹ R_a) · R_rel⁻¹ )``.
* **Prior residual** — each frame is pulled weakly toward its recorded sensor
  orientation, so an under-constrained region (a plain wall with two thin
  edges) stays where the gyroscope says it is instead of drifting.
* **Gravity residual** — the world-up direction expressed in each camera frame
  is pulled toward the measured one. This is what keeps the horizon level;
  without it a ring of weak edges can rotate the whole panorama about the
  optical axis and tilt the floor.

Edge residuals are Huber-weighted, so one bad-but-passing match cannot drag the
solution. Corrections are bounded: a solve that wants to move a camera more
than ``MAX_CORRECTION_DEG`` is reporting a parallax problem, not a refinement,
and is refused rather than applied.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field

import numpy as np

from ..sphere_math import DEG_TO_RAD, RAD_TO_DEG, Quat, Vec3
from .graph import GraphEdge, ImageGraph
from .matching import STATE_STRONG, STATE_WEAK
from .pairs import PairFrame

#: Weight of the recorded-orientation prior relative to one verified edge.
PRIOR_WEIGHT = 0.06
#: Weight of the gravity (level horizon) constraint.
GRAVITY_WEIGHT = 0.10
#: Huber threshold for edge residuals, in radians.
HUBER_DELTA_RAD = 1.5 * DEG_TO_RAD
#: A solution that needs more than this per frame is refused.
MAX_CORRECTION_DEG = 15.0
#: Levenberg–Marquardt iterations and damping schedule.
MAX_ITERATIONS = 24
INITIAL_DAMPING = 1e-3
FINAL_GRADIENT_TOLERANCE = 1e-6


@dataclass
class GlobalAlignment:
    """The joint solution and everything needed to audit it."""

    rotations: dict[int, Quat]
    initial: dict[int, Quat]
    converged: bool
    iterations: int
    edges_used: int
    weak_edges_used: int
    rms_residual_deg: float
    max_residual_deg: float
    corrections_deg: dict[int, float]
    worst_correction_deg: float
    gravity_rms_deg: float
    refused: bool
    message: str
    residual_by_edge: dict[tuple[int, int], float] = field(default_factory=dict)

    def as_dict(self) -> dict[str, object]:
        return {
            "converged": self.converged,
            "refused": self.refused,
            "iterations": self.iterations,
            "edgesUsed": self.edges_used,
            "weakEdgesUsed": self.weak_edges_used,
            "rmsResidualDeg": round(self.rms_residual_deg, 4),
            "maxResidualDeg": round(self.max_residual_deg, 4),
            "worstCorrectionDeg": round(self.worst_correction_deg, 3),
            "gravityRmsDeg": round(self.gravity_rms_deg, 4),
            "correctionsDeg": {
                str(k): round(v, 3) for k, v in sorted(self.corrections_deg.items())
            },
            "message": self.message,
        }


def log_rotation(quat: Quat) -> np.ndarray:
    """Rotation vector (axis · angle) of a unit quaternion, in radians."""
    q = quat
    if q.w < 0.0:  # shortest arc, so the log is continuous through ±180°
        q = Quat(-q.x, -q.y, -q.z, -q.w)
    vector = np.array([q.x, q.y, q.z], dtype=np.float64)
    norm = float(np.linalg.norm(vector))
    if norm < 1e-12:
        return np.zeros(3, dtype=np.float64)
    angle = 2.0 * math.atan2(norm, min(1.0, q.w))
    return vector / norm * angle


def exp_rotation(vector: np.ndarray) -> Quat:
    """Quaternion of a rotation vector, in radians."""
    theta = float(np.linalg.norm(vector))
    if theta < 1e-12:
        return Quat.identity()
    axis = vector / theta
    return Quat.axis_angle(theta * RAD_TO_DEG, Vec3(float(axis[0]), float(axis[1]), float(axis[2])))


def _angle_between(a: Quat, b: Quat) -> float:
    dot = abs(min(1.0, max(-1.0, (a * b.conjugate).w)))
    return 2.0 * math.acos(dot) * RAD_TO_DEG


def _up_in_camera(rotation: Quat) -> np.ndarray:
    world_up = rotation.conjugate.rotate(Vec3(0.0, 1.0, 0.0))
    return np.array([world_up.x, world_up.y, world_up.z], dtype=np.float64)


def _relative(a: Quat, b: Quat) -> Quat:
    """``R_b⁻¹ R_a`` — the relative rotation the matcher reports."""
    return b.conjugate * a


def _spanning_tree_initialisation(
    frames: list[PairFrame],
    edges: list[GraphEdge],
    measured: dict[int, Quat],
) -> dict[int, Quat]:
    """Grow rotations outward from the best-connected frame.

    Strong edges are consumed in confidence order, so the initial guess follows
    the trustworthy part of the graph; a frame reachable only through weak
    edges keeps its sensor orientation until the joint solve moves it.
    """
    adjacency: dict[int, list[tuple[int, GraphEdge]]] = {f.target_id: [] for f in frames}
    for edge in edges:
        if edge.state not in (STATE_STRONG, STATE_WEAK):
            continue
        if edge.a in adjacency and edge.b in adjacency:
            adjacency[edge.a].append((edge.b, edge))
            adjacency[edge.b].append((edge.a, edge))
    for node in adjacency:
        adjacency[node].sort(
            key=lambda item: (item[1].state != STATE_STRONG, -item[1].confidence)
        )

    degree = {tid: sum(1 for e in edges if e.state == STATE_STRONG and tid in (e.a, e.b)) for tid in adjacency}
    anchor = max(sorted(adjacency), key=lambda tid: degree.get(tid, 0))

    rotations: dict[int, Quat] = {anchor: measured.get(anchor, Quat.identity())}
    queue: deque[int] = deque([anchor])
    while queue:
        node = queue.popleft()
        for neighbour, edge in adjacency[node]:
            if neighbour in rotations:
                continue
            relative = _edge_relative(edge)
            if relative is None:
                continue
            if edge.a == node:
                # relative == R_b⁻¹ R_a, node is a → R_b = R_a · R_rel⁻¹
                rotations[neighbour] = (rotations[node] * relative.conjugate).normalized
            else:
                # node is b → R_a = R_b · R_rel
                rotations[neighbour] = (rotations[node] * relative).normalized
            queue.append(neighbour)

    for frame in frames:
        rotations.setdefault(frame.target_id, measured.get(frame.target_id, Quat.identity()))
    return rotations


def _edge_relative(edge: GraphEdge) -> Quat | None:
    return edge.relative_rotation


def align_global_rotations(
    frames: list[PairFrame],
    graph: ImageGraph,
    *,
    include_weak: bool = True,
    prior_weight: float = PRIOR_WEIGHT,
    gravity_weight: float = GRAVITY_WEIGHT,
) -> GlobalAlignment:
    """Jointly refine every camera rotation against the verified graph.

    Returns the measured orientations unchanged when there is nothing to solve
    (fewer than two frames, or no usable edge) — a session must never be made
    worse by an optimisation that had no evidence.
    """
    measured = {f.target_id: f.rotation for f in frames}
    if len(frames) < 2:
        return GlobalAlignment(
            rotations=dict(measured),
            initial=dict(measured),
            converged=True,
            iterations=0,
            edges_used=0,
            weak_edges_used=0,
            rms_residual_deg=0.0,
            max_residual_deg=0.0,
            corrections_deg={tid: 0.0 for tid in measured},
            worst_correction_deg=0.0,
            gravity_rms_deg=0.0,
            refused=False,
            message="A single photograph has nothing to align against.",
        )

    usable_states = {STATE_STRONG} | ({STATE_WEAK} if include_weak else set())
    edges = [
        e
        for e in graph.edges
        if e.state in usable_states and e.relative_rotation is not None
    ]
    if not edges:
        return GlobalAlignment(
            rotations=dict(measured),
            initial=dict(measured),
            converged=True,
            iterations=0,
            edges_used=0,
            weak_edges_used=0,
            rms_residual_deg=0.0,
            max_residual_deg=0.0,
            corrections_deg={tid: 0.0 for tid in measured},
            worst_correction_deg=0.0,
            gravity_rms_deg=0.0,
            refused=False,
            message="No verified image connection was available; recorded orientations kept.",
        )

    order = sorted(measured)
    index = {tid: i for i, tid in enumerate(order)}
    count = len(order)
    # The anchor is fixed so the solution has a gauge; it is the frame with the
    # most verified edges, i.e. the one the rest of the graph is best defined by.
    degree = {tid: graph.verified_degree(tid) for tid in order}
    anchor = max(order, key=lambda tid: degree.get(tid, 0))
    free = [tid for tid in order if tid != anchor]
    free_index = {tid: i for i, tid in enumerate(free)}

    initial = _spanning_tree_initialisation(frames, edges, measured)
    current = dict(initial)

    up_measured = {tid: _up_in_camera(measured[tid]) for tid in order}
    edge_pairs = [
        (index[e.a], index[e.b], e.a, e.b, _edge_relative(e), e.state)
        for e in edges
        if e.a in index and e.b in index
    ]

    def rotations_from(params: np.ndarray) -> dict[int, Quat]:
        result = dict(current)
        for tid in free:
            offset = 3 * free_index[tid]
            delta = params[offset : offset + 3]
            result[tid] = (exp_rotation(delta) * initial[tid]).normalized
        return result

    def residual(params: np.ndarray) -> tuple[np.ndarray, list[float]]:
        rotations = rotations_from(params)
        values: list[float] = []
        edge_residuals: list[float] = []
        for _ia, _ib, a, b, relative, state in edge_pairs:
            error = _relative(rotations[a], rotations[b]) * relative.conjugate
            vector = log_rotation(error)
            magnitude = float(np.linalg.norm(vector))
            weight = 1.0 if state == STATE_STRONG else 0.5
            # Huber: linear beyond the threshold so one outlier cannot dominate.
            if magnitude > HUBER_DELTA_RAD:
                scale = math.sqrt(HUBER_DELTA_RAD * (2.0 * magnitude - HUBER_DELTA_RAD)) / magnitude
                vector = vector * scale
            values.extend((vector * weight).tolist())
            edge_residuals.append(magnitude * RAD_TO_DEG)
        for tid in free:
            values.extend((log_rotation(rotations[tid] * measured[tid].conjugate) * prior_weight).tolist())
        for tid in free:
            up_error = _up_in_camera(rotations[tid]) - up_measured[tid]
            values.extend((up_error * gravity_weight).tolist())
        return np.asarray(values, dtype=np.float64), edge_residuals

    params = np.zeros(3 * len(free), dtype=np.float64)
    current_residual, edge_residuals = residual(params)
    cost = float(current_residual @ current_residual)
    damping = INITIAL_DAMPING
    iterations = 0
    converged = False

    if len(free) > 0 and len(edge_pairs) > 0:
        for iteration in range(MAX_ITERATIONS):
            iterations = iteration + 1
            # Numeric Jacobian: the residual is cheap and this keeps the
            # tangent-space convention in exactly one place (log_rotation).
            jacobian = np.zeros((current_residual.size, params.size), dtype=np.float64)
            epsilon = 1e-5
            for column in range(params.size):
                probe = params.copy()
                probe[column] += epsilon
                perturbed, _ = residual(probe)
                jacobian[:, column] = (perturbed - current_residual) / epsilon

            normal = jacobian.T @ jacobian
            gradient = jacobian.T @ current_residual
            normal += damping * np.eye(params.size)
            try:
                step = np.linalg.solve(normal, -gradient)
            except np.linalg.LinAlgError:
                damping *= 10.0
                continue

            candidate = params + step
            candidate_residual, candidate_edges = residual(candidate)
            candidate_cost = float(candidate_residual @ candidate_residual)
            if candidate_cost < cost:
                params = candidate
                current_residual = candidate_residual
                edge_residuals = candidate_edges
                cost = candidate_cost
                damping = max(damping / 3.0, 1e-9)
                if float(np.max(np.abs(step))) < FINAL_GRADIENT_TOLERANCE:
                    converged = True
                    break
            else:
                damping *= 8.0
                if damping > 1e8:
                    break

    solved = rotations_from(params)
    corrections = {
        tid: _angle_between(solved[tid], initial[tid]) for tid in order
    }
    worst = max(corrections.values()) if corrections else 0.0
    refused = worst > MAX_CORRECTION_DEG
    if refused:
        solved = dict(measured)
        corrections = {tid: 0.0 for tid in order}
        worst = 0.0

    residuals_array = np.asarray(edge_residuals, dtype=np.float64) if edge_residuals else np.zeros(1)
    rms = float(np.sqrt(np.mean(residuals_array**2)))
    maximum = float(np.max(residuals_array))
    gravity_rms = 0.0
    if len(free) > 0:
        gravity_errors = [
            math.degrees(
                math.acos(
                    max(-1.0, min(1.0, float(np.dot(_up_in_camera(solved[tid]), up_measured[tid]))))
                )
            )
            for tid in free
        ]
        gravity_rms = float(np.sqrt(np.mean(np.square(gravity_errors)))) if gravity_errors else 0.0

    # A residual this small means the graph is already self-consistent; the
    # iteration stopped because there was nothing left to remove, not because
    # it ran out of room.
    if not converged and not refused and rms < 0.02:
        converged = True

    if refused:
        message = (
            f"The joint solve wanted to move a camera by {worst:.1f}°, beyond the "
            f"{MAX_CORRECTION_DEG:.0f}° bound; the recorded orientations were kept. "
            "That usually means significant camera translation during capture."
        )
    elif converged:
        message = (
            f"All {len(order)} camera rotations solved jointly; residual "
            f"{rms:.2f}° RMS over {len(edges)} verified connections."
        )
    else:
        message = (
            f"Joint solve stopped after {iterations} iterations at {rms:.2f}° RMS; "
            "the result is usable but not fully converged."
        )

    return GlobalAlignment(
        rotations=solved,
        initial=initial,
        converged=converged,
        iterations=iterations,
        edges_used=sum(1 for e in edges if e.state == STATE_STRONG),
        weak_edges_used=sum(1 for e in edges if e.state == STATE_WEAK),
        rms_residual_deg=rms,
        max_residual_deg=maximum,
        corrections_deg=corrections,
        worst_correction_deg=worst,
        gravity_rms_deg=gravity_rms,
        refused=refused,
        message=message,
    )


__all__ = [
    "GRAVITY_WEIGHT",
    "GlobalAlignment",
    "MAX_CORRECTION_DEG",
    "PRIOR_WEIGHT",
    "align_global_rotations",
    "exp_rotation",
    "log_rotation",
]
