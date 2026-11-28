"""The session image graph: connectivity, loop closure and weak regions.

A panorama is only as good as the network of verified connections between its
photographs. A fully covered sphere whose graph has two components produces two
independently-aligned half-panoramas that tear along the boundary, so coverage
and connectivity are reported separately and both are required.

Only ``strong`` edges count as verified. ``weak`` edges are kept — they are
evidence that two frames overlap, and the stitcher may use them — but a region
whose only connections are weak is reported as weak rather than connected.
"""

from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass

from ..sphere_math import Quat
from .camera import (
    RING_LOWER,
    RING_MIDDLE,
    RING_POLAR_LOWER,
    RING_POLAR_UPPER,
    RING_UPPER,
)
from .matching import STATE_STRONG, STATE_WEAK, MatchVerdict
from .pairs import PairFrame

#: The four vertical relationships the panorama's structural integrity needs.
REQUIRED_VERTICAL_BANDS: tuple[tuple[str, str], ...] = (
    (RING_POLAR_UPPER, RING_UPPER),
    (RING_UPPER, RING_MIDDLE),
    (RING_MIDDLE, RING_LOWER),
    (RING_LOWER, RING_POLAR_LOWER),
)

BAND_NAMES = {
    (RING_POLAR_UPPER, RING_UPPER): "upper_polar_to_upper",
    (RING_UPPER, RING_MIDDLE): "upper_to_middle",
    (RING_MIDDLE, RING_LOWER): "middle_to_lower",
    (RING_LOWER, RING_POLAR_LOWER): "lower_to_lower_polar",
    (RING_POLAR_UPPER, RING_POLAR_UPPER): "upper_polar_ring",
    (RING_UPPER, RING_UPPER): "upper_ring",
    (RING_MIDDLE, RING_MIDDLE): "middle_ring",
    (RING_LOWER, RING_LOWER): "lower_ring",
    (RING_POLAR_LOWER, RING_POLAR_LOWER): "lower_polar_ring",
}


@dataclass(frozen=True, slots=True)
class GraphEdge:
    a: int
    b: int
    state: str
    inliers: int
    inlier_ratio: float
    median_error_px: float
    rings: tuple[str, str]
    confidence: float
    #: ``R_b⁻¹ R_a`` measured from the image pair; ``None`` when refused.
    #: Carried here so the solver does not have to re-pair verdicts with edges.
    relative_rotation: "Quat | None" = None

    @property
    def is_strong(self) -> bool:
        return self.state == STATE_STRONG

    def as_dict(self) -> dict[str, object]:
        return {
            "a": self.a,
            "b": self.b,
            "state": self.state,
            "inliers": self.inliers,
            "inlierRatio": round(self.inlier_ratio, 4),
            "medianErrorPx": round(self.median_error_px, 3),
            "rings": list(self.rings),
            "confidence": self.confidence,
        }


class ImageGraph:
    """Verified and unverified connections between a session's photographs."""

    def __init__(self, frames: list[PairFrame]) -> None:
        self.frames = {f.target_id: f for f in frames}
        self.edges: list[GraphEdge] = []
        self._adjacent: dict[int, list[GraphEdge]] = defaultdict(list)

    def add(self, first: int, second: int, verdict: MatchVerdict) -> GraphEdge:
        a, b = (first, second) if first < second else (second, first)
        rings = (
            self.frames[a].ring if a in self.frames else "unknown",
            self.frames[b].ring if b in self.frames else "unknown",
        )
        edge = GraphEdge(
            a=a,
            b=b,
            state=verdict.state,
            inliers=verdict.inliers,
            inlier_ratio=verdict.inlier_ratio,
            median_error_px=verdict.median_error_px,
            rings=rings,
            confidence=verdict.confidence,
            relative_rotation=verdict.relative_rotation,
        )
        self.edges.append(edge)
        self._adjacent[a].append(edge)
        self._adjacent[b].append(edge)
        return edge

    # -- structure -------------------------------------------------------

    def strong_edges(self) -> list[GraphEdge]:
        return [e for e in self.edges if e.is_strong]

    def edge_between(self, a: int, b: int) -> GraphEdge | None:
        key = (min(a, b), max(a, b))
        for edge in self.edges:
            if (edge.a, edge.b) == key:
                return edge
        return None

    def verified_degree(self, target_id: int) -> int:
        return sum(1 for e in self._adjacent.get(target_id, []) if e.is_strong)

    def components(self) -> list[set[int]]:
        """Connected components over **strong** edges only."""
        adjacency: dict[int, set[int]] = {tid: set() for tid in self.frames}
        for edge in self.strong_edges():
            if edge.a in adjacency and edge.b in adjacency:
                adjacency[edge.a].add(edge.b)
                adjacency[edge.b].add(edge.a)
        seen: set[int] = set()
        result: list[set[int]] = []
        for start in sorted(adjacency):
            if start in seen:
                continue
            component: set[int] = set()
            queue = deque([start])
            seen.add(start)
            while queue:
                node = queue.popleft()
                component.add(node)
                for neighbour in adjacency[node]:
                    if neighbour not in seen:
                        seen.add(neighbour)
                        queue.append(neighbour)
            result.append(component)
        return sorted(result, key=len, reverse=True)

    @property
    def is_connected(self) -> bool:
        if len(self.frames) <= 1:
            return True
        return len(self.components()) == 1

    def weak_nodes(self) -> list[int]:
        """Frames with no strong connection at all."""
        return sorted(tid for tid in self.frames if self.verified_degree(tid) == 0)

    def isolated_nodes(self) -> list[int]:
        """Frames with no candidate pair at all — no overlap was even possible."""
        return sorted(tid for tid in self.frames if not self._adjacent.get(tid))

    def band_summary(self) -> dict[str, dict[str, int]]:
        """Strong/weak/failed counts for each ring relationship."""
        summary: dict[str, dict[str, int]] = {
            name: {"strong": 0, "weak": 0, "failed": 0} for name in BAND_NAMES.values()
        }
        for edge in self.edges:
            pair = (edge.rings[0], edge.rings[1])
            name = BAND_NAMES.get(pair) or BAND_NAMES.get((pair[1], pair[0]))
            if name is None:
                name = "cross_ring"
                summary.setdefault(name, {"strong": 0, "weak": 0, "failed": 0})
            bucket = "strong" if edge.is_strong else (
                "weak" if edge.state == STATE_WEAK else "failed"
            )
            summary[name][bucket] += 1
        return summary

    def missing_vertical_bands(self) -> list[str]:
        """Required vertical relationships with no strong edge."""
        summary = self.band_summary()
        return [
            BAND_NAMES[pair]
            for pair in REQUIRED_VERTICAL_BANDS
            if summary.get(BAND_NAMES[pair], {}).get("strong", 0) == 0
        ]

    def loop_closure(self) -> dict[str, object]:
        """Whether the horizon ring closes into a cycle.

        A ring that is a chain rather than a cycle leaves the 0°/360° seam
        unconstrained, which is where a panorama most often shows a visible
        step. Closure needs every middle frame in one component *and* two or
        more strong horizontal edges per frame.
        """
        middle = sorted(tid for tid, f in self.frames.items() if f.ring == RING_MIDDLE)
        if len(middle) < 3:
            return {"closed": False, "reason": "Fewer than three middle-ring photographs."}
        horizontal = defaultdict(int)
        for edge in self.strong_edges():
            if edge.rings == (RING_MIDDLE, RING_MIDDLE):
                horizontal[edge.a] += 1
                horizontal[edge.b] += 1
        under_connected = [tid for tid in middle if horizontal[tid] < 2]
        component = next(
            (c for c in self.components() if middle[0] in c), set()
        )
        all_together = all(tid in component for tid in middle)
        closed = all_together and not under_connected
        return {
            "closed": closed,
            "middleFrames": len(middle),
            "underConnected": under_connected,
            "allInOneComponent": all_together,
            "reason": None
            if closed
            else (
                "The horizon ring is not a closed cycle: "
                + (
                    f"{len(under_connected)} frames have fewer than two strong "
                    "horizontal connections"
                    if under_connected
                    else "the middle frames span more than one component"
                )
                + "."
            ),
        }

    def diagnostics(self) -> dict[str, object]:
        components = self.components()
        return {
            "frames": len(self.frames),
            "edges": len(self.edges),
            "strongEdges": len(self.strong_edges()),
            "weakEdges": sum(1 for e in self.edges if e.state == STATE_WEAK),
            "failedEdges": sum(
                1 for e in self.edges if e.state not in (STATE_STRONG, STATE_WEAK)
            ),
            "connected": self.is_connected,
            "components": [sorted(c) for c in components],
            "largestComponent": len(components[0]) if components else 0,
            "weakFrames": self.weak_nodes(),
            "isolatedFrames": self.isolated_nodes(),
            "bands": self.band_summary(),
            "missingVerticalBands": self.missing_vertical_bands(),
            "loopClosure": self.loop_closure(),
        }


def build_graph(
    frames: list[PairFrame],
    verdicts: list[tuple[int, int, MatchVerdict]],
) -> ImageGraph:
    """Assemble the graph from already-verified pairs."""
    graph = ImageGraph(frames)
    for first, second, verdict in verdicts:
        graph.add(first, second, verdict)
    return graph


__all__ = [
    "BAND_NAMES",
    "GraphEdge",
    "ImageGraph",
    "REQUIRED_VERTICAL_BANDS",
    "build_graph",
]
