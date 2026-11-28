"""Session-level orchestration: matching, the graph, the joint solve, coverage.

This is the single entry point both the durable panorama worker and the
incremental capture endpoint call, so a session can never be evaluated two
different ways depending on which path reached it.

The distinction the report insists on is between

* a **geometrically complete sphere** — every direction covered by a
  photograph, and
* an **alignable panorama** — a connected, verified image network.

They are reported separately. A session can be complete and still not
alignable (plain white walls everywhere), and it can be well connected while
missing a patch of ceiling. Marking either one as "done" without the other is
how a broken panorama reaches an administrator as inspection evidence.
"""

from __future__ import annotations

import logging
import math
import time
from dataclasses import dataclass, field

from ..sphere_math import Quat
from .camera import PinholeCamera
from .coverage import CoverageReport, FrameFootprint, measure_coverage, suggest_extra_directions
from .features import (
    DESCRIPTOR_ORB,
    DESCRIPTOR_SIFT,
    FeatureSet,
    extract_orb_features,
    extract_sift_features,
)
from .global_rotation import GlobalAlignment, align_global_rotations
from .graph import ImageGraph, build_graph
from .matching import (
    DEFAULT_THRESHOLDS,
    STATE_WEAK,
    MatchThresholds,
    MatchVerdict,
    PairMatcher,
    verify_pair_cascaded,
)
from .pairs import PairFrame, candidate_pairs, pairs_for_frame

logger = logging.getLogger("sitewise.panorama.alignment.session")

#: Final quality states. Only ``verified`` may be presented as inspection
#: evidence; the others remain reviewable drafts.
QUALITY_VERIFIED = "verified"
QUALITY_DRAFT = "draft"
QUALITY_INSUFFICIENT = "insufficient"

#: A sphere this complete counts as covered for the *draft* state. The
#: verified state still requires exact 100% on the sampling grid.
DRAFT_COVERAGE_FLOOR = 0.985
#: Minimum verified edges per frame for a connected, reviewable network.
MIN_VERIFIED_DEGREE = 2


@dataclass(frozen=True, slots=True)
class FrameAlignmentInput:
    """One accepted photograph, as the aligner needs it."""

    target_id: int
    image_path: str
    rotation: Quat
    width: int
    height: int
    focal: float
    cx: float | None = None
    cy: float | None = None

    @property
    def camera(self) -> PinholeCamera:
        return PinholeCamera(
            width=self.width,
            height=self.height,
            focal=self.focal,
            cx=self.cx,
            cy=self.cy,
        )


@dataclass
class SessionAlignment:
    """The full evaluation of one capture session."""

    frames: list[PairFrame]
    verdicts: list[tuple[int, int, MatchVerdict]]
    graph: ImageGraph
    coverage: CoverageReport
    global_alignment: GlobalAlignment
    quality_state: str
    blockers: list[str]
    warnings: list[str]
    suggested_targets: list[tuple[float, float]] = field(default_factory=list)
    thresholds: MatchThresholds = DEFAULT_THRESHOLDS
    #: Wall-clock milliseconds per stage, keyed by a stable name. Measured, not
    #: estimated — the post-capture screen reports these numbers and nothing
    #: else, so no progress bar is ever driven by a guess.
    stage_timings: dict[str, float] = field(default_factory=dict)
    #: How many pairs each detector actually decided, for the report.
    detector_usage: dict[str, int] = field(default_factory=dict)

    @property
    def is_verified(self) -> bool:
        return self.quality_state == QUALITY_VERIFIED

    def refined_rotation(self, target_id: int) -> Quat | None:
        return self.global_alignment.rotations.get(target_id)

    def as_dict(self) -> dict[str, object]:
        return {
            "qualityState": self.quality_state,
            "blockers": self.blockers,
            "warnings": self.warnings,
            "suggestedTargets": [
                {"yawDeg": round(y, 2), "pitchDeg": round(p, 2)}
                for y, p in self.suggested_targets
            ],
            "coverage": self.coverage.as_dict(),
            "graph": self.graph.diagnostics(),
            "globalAlignment": self.global_alignment.as_dict(),
            "thresholds": self.thresholds.as_dict(),
            "stageTimingsMs": {k: round(v, 1) for k, v in self.stage_timings.items()},
            "detectorUsage": dict(self.detector_usage),
            "frames": [
                {
                    "targetId": f.target_id,
                    "pitchDeg": round(f.pitch_deg, 2),
                    "yawDeg": round(f.yaw_deg, 2),
                    "ring": f.ring,
                    "verifiedDegree": self.graph.verified_degree(f.target_id),
                }
                for f in sorted(self.frames, key=lambda f: f.target_id)
            ],
            "edges": [
                {**e.as_dict(), "priority": None} for e in self.graph.edges
            ],
        }


def _pair_frame(item: FrameAlignmentInput) -> PairFrame:
    return PairFrame(
        target_id=item.target_id,
        rotation=item.rotation,
        camera=item.camera,
    )


def _coverage_footprints(
    frames: list[PairFrame], rotations: dict[int, Quat]
) -> list[FrameFootprint]:
    return [
        FrameFootprint(
            target_id=frame.target_id,
            rotation=rotations.get(frame.target_id, frame.rotation),
            camera=frame.camera,
        )
        for frame in frames
    ]


def evaluate_completion(
    graph: ImageGraph,
    coverage: CoverageReport,
    alignment: GlobalAlignment,
) -> tuple[str, list[str], list[str]]:
    """``(quality_state, blockers, warnings)`` for the evaluated session."""
    blockers: list[str] = []
    warnings: list[str] = []

    if not coverage.is_complete:
        if coverage.uncovered > 1.0 - DRAFT_COVERAGE_FLOOR:
            blockers.append(
                f"{coverage.uncovered * 100:.1f}% of the sphere is uncovered"
                + (
                    f"; the largest gap is centred near "
                    f"{coverage.largest_uncovered.centre_latitude_deg:.0f}°, "
                    f"{coverage.largest_uncovered.centre_longitude_deg:.0f}°."
                    if coverage.largest_uncovered
                    else "."
                )
            )
        else:
            warnings.append(
                f"{coverage.uncovered * 100:.1f}% of the sphere is uncovered; "
                "the panorama is a draft rather than verified evidence."
            )

    if coverage.zenith < 0.999:
        warnings.append(
            f"Ceiling coverage is {coverage.zenith * 100:.1f}% of the polar band."
        )
    if coverage.nadir < 0.999:
        warnings.append(
            f"Floor coverage is {coverage.nadir * 100:.1f}% of the polar band."
        )
    if not coverage.has_seam_band:
        warnings.append(
            f"Only {coverage.double * 100:.1f}% of the sphere has two-photograph "
            "overlap; seams will have a narrow blend band."
        )

    if not graph.is_connected:
        blockers.append(
            f"The image graph has {len(graph.components())} disconnected groups; "
            "the panorama would tear where they meet."
        )

    missing_bands = graph.missing_vertical_bands()
    if missing_bands:
        readable = ", ".join(band.replace("_", " ") for band in missing_bands)
        blockers.append(f"No verified cross-ring connection for: {readable}.")

    loop = graph.loop_closure()
    if not bool(loop.get("closed")):
        blockers.append(
            str(loop.get("reason") or "The horizon ring is not closed.")
        )

    under_connected = [
        tid for tid in sorted(graph.frames) if graph.verified_degree(tid) < MIN_VERIFIED_DEGREE
    ]
    if under_connected:
        blockers.append(
            f"{len(under_connected)} photograph(s) have fewer than "
            f"{MIN_VERIFIED_DEGREE} verified connections "
            f"(targets {under_connected[:6]})."
        )

    weak = graph.weak_nodes()
    if weak:
        warnings.append(
            f"{len(weak)} photograph(s) sit in weakly-matched regions "
            f"(targets {weak[:6]}); review them before relying on the panorama."
        )

    if alignment.refused:
        blockers.append(alignment.message)
    elif alignment.worst_correction_deg > 5.0:
        warnings.append(
            f"The joint solve corrected a camera by "
            f"{alignment.worst_correction_deg:.1f}°; check for camera movement "
            "during capture."
        )
    if alignment.gravity_rms_deg > 3.0:
        warnings.append(
            f"Horizon consistency is {alignment.gravity_rms_deg:.1f}° RMS, "
            "which may show as a tilted floor."
        )

    if blockers:
        return QUALITY_INSUFFICIENT, blockers, warnings
    if coverage.double < 0.95 or weak:
        return QUALITY_DRAFT, blockers, warnings
    return QUALITY_VERIFIED, blockers, warnings


def align_session(
    inputs: list[FrameAlignmentInput],
    *,
    thresholds: MatchThresholds = DEFAULT_THRESHOLDS,
    on_stage=None,
    measure_spherical_coverage: bool = True,
) -> SessionAlignment:
    """Match every candidate pair, build the graph, solve rotations, measure coverage."""
    def stage(message: str) -> None:
        if on_stage is not None:
            on_stage(message)

    frames = [_pair_frame(item) for item in sorted(inputs, key=lambda i: i.target_id)]
    by_id = {item.target_id: item for item in inputs}
    pairs = candidate_pairs(frames)

    matcher = PairMatcher()
    # Two caches, one per detector. A frame is extracted once for ORB (always)
    # and once for SIFT only if some required pair could not be verified with
    # ORB, so the expensive descriptors are paid for only where they are used.
    orb_cache: dict[int, FeatureSet | None] = {}
    sift_cache: dict[int, FeatureSet | None] = {}
    verdicts: list[tuple[int, int, MatchVerdict]] = []
    detector_usage = {DESCRIPTOR_ORB: 0, DESCRIPTOR_SIFT: 0}
    timings: dict[str, float] = {}
    extraction_ms = 0.0

    def orb_for(target_id: int) -> FeatureSet | None:
        nonlocal extraction_ms
        if target_id not in orb_cache:
            started = time.perf_counter()
            orb_cache[target_id] = extract_orb_features(by_id[target_id].image_path)
            extraction_ms += (time.perf_counter() - started) * 1000.0
        return orb_cache[target_id]

    def sift_for(target_id: int) -> FeatureSet | None:
        nonlocal extraction_ms
        if target_id not in sift_cache:
            started = time.perf_counter()
            sift_cache[target_id] = extract_sift_features(by_id[target_id].image_path)
            extraction_ms += (time.perf_counter() - started) * 1000.0
        return sift_cache[target_id]

    stage(f"Matching {len(pairs)} candidate image pairs…")
    matching_started = time.perf_counter()
    for index, pair in enumerate(pairs, start=1):
        first_input = by_id.get(pair.first)
        second_input = by_id.get(pair.second)
        if first_input is None or second_input is None:
            continue
        if index % 8 == 0 or index == len(pairs):
            stage(f"Matching image pairs: {index}/{len(pairs)}…")
        prior = _prior_relative(first_input.rotation, second_input.rotation)
        verdict = verify_pair_cascaded(
            pair.first,
            pair.second,
            first_camera=first_input.camera,
            second_camera=second_input.camera,
            prior_relative_rotation=prior,
            thresholds=thresholds,
            matcher=matcher,
            orb_features=orb_for,
            sift_features=sift_for,
        )
        detector_usage[verdict.detector] = detector_usage.get(verdict.detector, 0) + 1
        verdicts.append((pair.first, pair.second, verdict))
    timings["pairMatching"] = (time.perf_counter() - matching_started) * 1000.0
    timings["featureExtraction"] = extraction_ms

    graph_started = time.perf_counter()
    graph = build_graph(frames, verdicts)
    timings["graphBuild"] = (time.perf_counter() - graph_started) * 1000.0

    stage("Optimising all camera orientations jointly…")
    solve_started = time.perf_counter()
    alignment = align_global_rotations(frames, graph)
    timings["globalRotation"] = (time.perf_counter() - solve_started) * 1000.0

    if measure_spherical_coverage:
        stage("Measuring spherical coverage…")
        coverage_started = time.perf_counter()
        coverage = measure_coverage(_coverage_footprints(frames, alignment.rotations))
        timings["coverage"] = (time.perf_counter() - coverage_started) * 1000.0
    else:
        coverage = measure_coverage([])

    state, blockers, warnings = evaluate_completion(graph, coverage, alignment)
    suggested = suggest_extra_directions(coverage)
    timings["total"] = sum(
        value for key, value in timings.items() if key != "total"
    )
    return SessionAlignment(
        frames=frames,
        verdicts=verdicts,
        graph=graph,
        coverage=coverage,
        global_alignment=alignment,
        quality_state=state,
        blockers=blockers,
        warnings=warnings,
        suggested_targets=suggested,
        thresholds=thresholds,
        stage_timings=timings,
        detector_usage=detector_usage,
    )


def _prior_relative(first: Quat, second: Quat) -> Quat:
    """``R_b⁻¹ R_a`` from the recorded poses, matching the matcher's convention."""
    return second.conjugate * first


@dataclass
class IncrementalMatchResult:
    """What the capture screen needs after one new photograph."""

    target_id: int
    verdicts: list[tuple[int, MatchVerdict]]
    graph: ImageGraph
    coverage: CoverageReport | None
    quality_state: str
    blockers: list[str]
    warnings: list[str]

    @property
    def best_connection(self) -> MatchVerdict | None:
        strong = [v for _t, v in self.verdicts if v.is_strong]
        if not strong:
            return None
        return max(strong, key=lambda v: v.confidence)

    @property
    def verified_connections(self) -> int:
        return sum(1 for _t, v in self.verdicts if v.is_strong)

    def as_dict(self) -> dict[str, object]:
        best = self.best_connection
        return {
            "targetId": self.target_id,
            "state": (
                "verified"
                if self.verified_connections >= MIN_VERIFIED_DEGREE
                else ("weak" if self.verdicts else "pending")
            ),
            "verifiedConnections": self.verified_connections,
            "matches": [
                {"targetId": tid, **verdict.as_dict()}
                for tid, verdict in sorted(self.verdicts, key=lambda item: -item[1].confidence)
            ],
            "best": best.as_dict() if best else None,
            "graph": self.graph.diagnostics(),
            "coverage": self.coverage.as_dict() if self.coverage else None,
            "qualityState": self.quality_state,
            "blockers": self.blockers,
            "warnings": self.warnings,
        }


def match_new_frame(
    new_frame: FrameAlignmentInput,
    accepted: list[FrameAlignmentInput],
    *,
    partner_ids: set[int] | None = None,
    thresholds: MatchThresholds = DEFAULT_THRESHOLDS,
    on_stage=None,
) -> IncrementalMatchResult:
    """Match one freshly accepted photograph against the accepted set.

    Only pairs that genuinely overlap are attempted — the candidate planner
    decides that from orientation and footprint, not from adjacency in the
    capture order. The result is reported immediately so the capture screen can
    say "image connection verified" or "weak image connection" without waiting
    for the whole session.

    [partner_ids] restricts the attempt to those targets. The capture endpoint
    uses it to download only the photographs that actually overlap the new
    frame instead of the whole session.
    """
    def stage(message: str) -> None:
        if on_stage is not None:
            on_stage(message)

    frames = [_pair_frame(item) for item in accepted]
    if all(frame.target_id != new_frame.target_id for frame in frames):
        frames.append(_pair_frame(new_frame))
    by_id = {item.target_id: item for item in accepted}
    by_id[new_frame.target_id] = new_frame

    pairs = pairs_for_frame(candidate_pairs(frames), new_frame.target_id)
    if partner_ids is not None:
        pairs = [
            pair
            for pair in pairs
            if (pair.second if pair.first == new_frame.target_id else pair.first)
            in partner_ids
        ]
    stage(f"Checking image alignment against {len(pairs)} overlapping photographs…")

    # The incremental path uses the same cascade as the full session, so a pair
    # cannot be verified during capture and refused during generation. ORB runs
    # first; SIFT is extracted only for pairs ORB could not verify.
    matcher = PairMatcher()
    new_orb_cache: dict[int, FeatureSet | None] = {}
    new_sift_cache: dict[int, FeatureSet | None] = {}

    def orb_for(target_id: int) -> FeatureSet | None:
        if target_id not in new_orb_cache:
            item = by_id[target_id]
            new_orb_cache[target_id] = extract_orb_features(item.image_path)
        return new_orb_cache[target_id]

    def sift_for(target_id: int) -> FeatureSet | None:
        if target_id not in new_sift_cache:
            item = by_id[target_id]
            new_sift_cache[target_id] = extract_sift_features(item.image_path)
        return new_sift_cache[target_id]

    new_features = orb_for(new_frame.target_id)
    verdicts: list[tuple[int, MatchVerdict]] = []
    if new_features is not None:
        for pair in pairs:
            other_id = pair.second if pair.first == new_frame.target_id else pair.first
            other = by_id.get(other_id)
            if other is None:
                continue
            if orb_for(other_id) is None:
                # The neighbour could not be decoded; a failure here would be
                # about that photograph, not about the new one.
                continue
            verdict = verify_pair_cascaded(
                new_frame.target_id,
                other_id,
                first_camera=new_frame.camera,
                second_camera=other.camera,
                prior_relative_rotation=_prior_relative(
                    new_frame.rotation, other.rotation
                ),
                thresholds=thresholds,
                matcher=matcher,
                orb_features=orb_for,
                sift_features=sift_for,
            )
            verdicts.append((other_id, verdict))

    graph = build_graph(frames, [(new_frame.target_id, tid, v) for tid, v in verdicts])

    # Frame-level reporting only. Session-level gates (coverage, loop closure,
    # connectivity) are meaningless here: the session is still being captured,
    # and reporting "0% coverage" after the second photograph would train the
    # photographer to ignore the status.
    strong = [v for _t, v in verdicts if v.is_strong]
    weak = [v for _t, v in verdicts if v.state == STATE_WEAK]
    blockers: list[str] = []
    warnings: list[str] = []
    if new_features is None:
        blockers.append("The photograph could not be decoded for matching.")
    elif not verdicts:
        blockers.append(
            "No previously captured photograph overlaps this direction; "
            "capture a neighbouring target first."
        )
    elif not strong:
        warnings.append(
            "Weak image connection: no overlapping photograph produced enough "
            "verified correspondences. Plain walls and reflective surfaces "
            "cause this; an extra bridging photograph usually fixes it."
        )
    if strong and len(strong) < MIN_VERIFIED_DEGREE:
        warnings.append(
            f"Only {len(strong)} verified connection so far; the panorama needs "
            f"at least {MIN_VERIFIED_DEGREE} per photograph."
        )
    if weak:
        warnings.append(
            f"{len(weak)} overlapping photograph(s) matched weakly: "
            + "; ".join(f"target {tid} — {v.reason}" for tid, v in weak[:2])
        )

    return IncrementalMatchResult(
        target_id=new_frame.target_id,
        verdicts=verdicts,
        graph=graph,
        coverage=None,
        quality_state=(
            "verified"
            if len(strong) >= MIN_VERIFIED_DEGREE
            else ("connected" if strong else ("weak" if weak else "pending"))
        ),
        blockers=blockers,
        warnings=warnings,
    )


def session_summary(alignment: SessionAlignment) -> dict[str, object]:
    """Compact summary for logging and the admin coverage panel."""
    return {
        "qualityState": alignment.quality_state,
        "frames": len(alignment.frames),
        "strongEdges": len(alignment.graph.strong_edges()),
        "coverageSingle": round(alignment.coverage.single, 4),
        "coverageDouble": round(alignment.coverage.double, 4),
        "rmsResidualDeg": round(alignment.global_alignment.rms_residual_deg, 3),
        "blockers": alignment.blockers,
    }


__all__ = [
    "DRAFT_COVERAGE_FLOOR",
    "FrameAlignmentInput",
    "IncrementalMatchResult",
    "MIN_VERIFIED_DEGREE",
    "QUALITY_DRAFT",
    "QUALITY_INSUFFICIENT",
    "QUALITY_VERIFIED",
    "SessionAlignment",
    "align_session",
    "evaluate_completion",
    "match_new_frame",
    "session_summary",
]
