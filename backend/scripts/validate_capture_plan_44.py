"""Validate a 44-target capture plan against the measured camera projection.

This is an offline geometry check. It answers three questions for a candidate
plan, using the same pinhole model the device uses:

1. Is the previously captured target inside the current frame (with margin)?
2. Do consecutive frames share enough spherical area to register?
3. Does the target set cover the whole sphere, poles included?

It does not touch the database, the storage bucket or any captured session.

Usage::

    python backend/scripts/validate_capture_plan_44.py
    python backend/scripts/validate_capture_plan_44.py --pitch 62 --margin 0.94
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass

#: Captured still: 3072 x 4096 portrait.
IMAGE_W = 3072
IMAGE_H = 4096
#: Conservative end of the measured 67-69 degree vertical band.
VFOV_DEG = 65.0

HALF_W = IMAGE_W / 2
HALF_H = IMAGE_H / 2
FOCAL = HALF_H / math.tan(math.radians(VFOV_DEG) / 2)
TAN_H = HALF_W / FOCAL
TAN_V = HALF_H / FOCAL


@dataclass(frozen=True)
class Target:
    tid: int
    ring: str
    yaw: float
    pitch: float


def direction(yaw_deg: float, pitch_deg: float) -> tuple[float, float, float]:
    y, p = math.radians(yaw_deg), math.radians(pitch_deg)
    return (math.cos(p) * math.sin(y), math.cos(p) * math.cos(y), math.sin(p))


def camera_basis(yaw_deg: float, pitch_deg: float):
    f = direction(yaw_deg, pitch_deg)
    # Right vector: forward x world-up, normalised. Zero roll is assumed, which
    # is what the gravity-aligned preview shows.
    rx = f[1] * 1.0 - f[2] * 0.0
    ry = f[2] * 0.0 - f[0] * 1.0
    rz = 0.0
    n = math.sqrt(rx * rx + ry * ry + rz * rz)
    r = (rx / n, ry / n, rz / n)
    u = (
        r[1] * f[2] - r[2] * f[1],
        r[2] * f[0] - r[0] * f[2],
        r[0] * f[1] - r[1] * f[0],
    )
    return r, u, f


def project(target: Target, cam: Target) -> tuple[float, float, float] | None:
    """Normalised image position of ``target`` seen from ``cam``.

    Returns ``(x, y, depth)`` where |x| <= 1 and |y| <= 1 means the target is
    inside the saved photograph. ``depth`` is the cosine of the angle between
    the two directions; <= 0 means behind the camera.
    """
    r, u, f = camera_basis(cam.yaw, cam.pitch)
    p = direction(target.yaw, target.pitch)
    depth = p[0] * f[0] + p[1] * f[1] + p[2] * f[2]
    if depth <= 1e-6:
        return None
    x = (p[0] * r[0] + p[1] * r[1] + p[2] * r[2]) / depth / TAN_H
    y = (p[0] * u[0] + p[1] * u[1] + p[2] * u[2]) / depth / TAN_V
    return x, y, depth


def angular_sep(a: Target, b: Target) -> float:
    da = direction(a.yaw, a.pitch)
    db = direction(b.yaw, b.pitch)
    dot = max(-1.0, min(1.0, sum(i * j for i, j in zip(da, db))))
    return math.degrees(math.acos(dot))


def overlap(a: Target, b: Target) -> float:
    """Shared spherical area as a fraction of the smaller footprint.

    Both frames are rectangles on the sphere; the smaller one is the reference
    because a seam only needs the narrower frame to be covered.
    """
    da = direction(a.yaw, a.pitch)
    db = direction(b.yaw, b.pitch)
    # Solid angle of the intersection, estimated by sampling the smaller frame.
    corners_a = _frame_corners(a)
    corners_b = _frame_corners(b)
    # Sample the frame whose angular radius is smaller.
    if _radius(a) <= _radius(b):
        samples, ref = corners_a, a
    else:
        samples, ref = corners_b, b
    inside = 0
    for sx, sy in samples:
        p = _pixel_direction(ref, sx, sy)
        # Inside the other frame?
        x, y, depth = _project_dir(p, b)
        if depth is not None and abs(x) <= 1 and abs(y) <= 1:
            inside += 1
    return inside / len(samples)


def _radius(t: Target) -> float:
    return math.hypot(math.degrees(math.atan(TAN_H)), math.degrees(math.atan(TAN_V)))


def _pixel_direction(t: Target, sx: float, sy: float):
    r, u, f = camera_basis(t.yaw, t.pitch)
    x, y = sx * TAN_H, sy * TAN_V
    v = (f[0] + r[0] * x + u[0] * y,
         f[1] + r[1] * x + u[1] * y,
         f[2] + r[2] * x + u[2] * y)
    n = math.sqrt(sum(i * i for i in v))
    return (v[0] / n, v[1] / n, v[2] / n)


def _frame_corners(t: Target, steps: int = 9):
    pts = []
    for i in range(steps):
        for j in range(steps):
            sx = -1 + 2 * i / (steps - 1)
            sy = -1 + 2 * j / (steps - 1)
            pts.append((sx, sy))
    return pts


def _project_dir(p, cam: Target):
    r, u, f = camera_basis(cam.yaw, cam.pitch)
    depth = sum(i * j for i, j in zip(p, f))
    if depth <= 1e-6:
        return 0.0, 0.0, None
    x = sum(i * j for i, j in zip(p, r)) / depth / TAN_H
    y = sum(i * j for i, j in zip(p, u)) / depth / TAN_V
    return x, y, depth


# --------------------------------------------------------------------------
# Geometry candidates
# --------------------------------------------------------------------------


def build_rings(upper_pitch: float, polar_pitch: float, stagger: float,
                cap_offset: float = 0.0, floor_offset: float = 30.0):
    main = [i * 30.0 for i in range(12)]
    upper = [(y + stagger) % 360 for y in main]
    lower = [(y + stagger) % 360 for y in main]
    caps = [(cap_offset + 90 * i) % 360 for i in range(4)]
    floors = [(floor_offset + 90 * i) % 360 for i in range(4)]
    return {
        "upper_polar": caps,
        "upper": upper,
        "middle": main,
        "lower": lower,
        "lower_polar": floors,
    }, {"upper_polar": polar_pitch, "upper": upper_pitch,
        "middle": 0.0, "lower": -upper_pitch, "lower_polar": -polar_pitch}


def table(rings, pitches) -> list[Target]:
    out = []
    tid = 1
    for key in ("upper_polar", "upper", "middle", "lower", "lower_polar"):
        for yaw in rings[key]:
            out.append(Target(tid, key, yaw, pitches[key]))
            tid += 1
    return out


def by_yaw(rows, ring, yaw):
    for r in rows:
        if r.ring == ring and abs((r.yaw - yaw + 180) % 360 - 180) < 1e-6:
            return r
    raise KeyError((ring, yaw))


#: Traversal derived from the hub-and-gap structure, in (ring, yaw) order.
#: Ceiling caps sit between the two upper targets that flank them, floor caps
#: between the two lower targets, so each cap unit spans one middle-ring step:
#:
#:     M330 -> U345 -> C0 -> U15 -> M0     (a ceiling arch)
#:     M0   -> L15  -> F30 -> L45 -> M30   (a floor arch)
#:
#: Four leftover lower targets have no visible neighbour left once the arches
#: claim their pairs; each is inserted with one unavoidable 60-degree jump,
#: which the report names explicitly.
_ORDER: tuple[tuple[str, float], ...] = (
    ("lower", 345), ("middle", 330), ("upper", 345), ("upper_polar", 0),
    ("upper", 15), ("middle", 0), ("lower", 15), ("lower_polar", 30),
    ("lower", 45), ("middle", 30), ("upper", 45), ("lower", 75),
    ("middle", 60), ("upper", 75), ("upper_polar", 90), ("upper", 105),
    ("middle", 90), ("lower", 105), ("lower_polar", 120), ("lower", 135),
    ("middle", 120), ("upper", 135), ("lower", 165), ("middle", 150),
    ("upper", 165), ("upper_polar", 180), ("upper", 195), ("middle", 180),
    ("lower", 195), ("lower_polar", 210), ("lower", 225), ("middle", 210),
    ("upper", 225), ("lower", 255), ("middle", 240), ("upper", 255),
    ("upper_polar", 270), ("upper", 285), ("middle", 270), ("lower", 285),
    ("lower_polar", 300), ("lower", 315), ("middle", 300), ("upper", 315),
)


def arch_order(rows, margin: float) -> list[Target]:
    """The published traversal, resolved against the generated ring table."""
    order = []
    for ring, yaw in _ORDER:
        order.append(by_yaw(rows, ring, yaw))
    if len({t.tid for t in order}) != len(rows):
        raise SystemExit(f"order covers {len(order)} of {len(rows)} targets")
    return order


def coverage(rows: list[Target], step: float = 2.0):
    """Fraction of the sphere inside at least one frame, plus pole checks."""
    covered = total = 0
    single = 0
    pole_hits = {"zenith": 0, "nadir": 0}
    lat = -90.0
    while lat <= 90.0:
        lon = 0.0
        while lon < 360.0:
            total += 1
            hit = 0
            for t in rows:
                proj = project(Target(0, "", lon, lat), t)
                if proj is None:
                    continue
                x, y, _ = proj
                if abs(x) <= 1 and abs(y) <= 1:
                    hit += 1
            if hit:
                covered += 1
            if hit >= 2:
                single += 1
            if lat >= 88.0 and hit:
                pole_hits["zenith"] += 1
            if lat <= -88.0 and hit:
                pole_hits["nadir"] += 1
            lon += step
        lat += step
    return covered / total, single / total, pole_hits


def evaluate(rows, order, margin: float, verbose: bool):
    worst = []
    failures = []
    for prev, cur in zip(order, order[1:]):
        proj = project(prev, cur)
        if proj is None:
            failures.append((prev.tid, cur.tid, "behind", 99.0))
            continue
        x, y, _ = proj
        m = max(abs(x), abs(y))
        worst.append((m, prev.tid, cur.tid, prev.ring, cur.ring, x, y))
        if m > margin:
            failures.append((prev.tid, cur.tid, f"{x:+.3f},{y:+.3f}", m))
    worst.sort(reverse=True)
    if verbose:
        print("  tightest transitions (fraction of half-frame):")
        for m, a, b, ra, rb, x, y in worst[:6]:
            print(f"    {a:>2}({ra:<11}) -> {b:>2}({rb:<11}) "
                  f"x={x:+.3f} y={y:+.3f}  |max|={m:.4f}")
    return worst, failures


def pair_overlaps(rows):
    vals = []
    for i, a in enumerate(rows):
        for b in rows[i + 1:]:
            sep = angular_sep(a, b)
            if sep > 60:
                continue
            vals.append((overlap(a, b), a.tid, b.tid, sep))
    vals.sort(reverse=True)
    return vals


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pitch", type=float, default=62.0)
    ap.add_argument("--upper", type=float, default=30.0)
    ap.add_argument("--stagger", type=float, default=15.0)
    ap.add_argument("--margin", type=float, default=0.94)
    ap.add_argument("--legacy", action="store_true",
                    help="evaluate the historical aligned-ring 44 order")
    args = ap.parse_args()

    print(f"camera: {IMAGE_W}x{IMAGE_H} vFOV={VFOV_DEG} "
          f"f={FOCAL:.1f}px hFOV={2*math.degrees(math.atan(TAN_H)):.2f}deg")

    rings, pitches = build_rings(args.upper, args.pitch, args.stagger)
    rows = table(rings, pitches)
    print(f"targets: {len(rows)}  polar={args.pitch} upper={args.upper} "
          f"stagger={args.stagger}")

    if args.legacy:
        order = []
        for key in ("upper_polar", "upper", "middle", "lower", "lower_polar"):
            order.extend([r for r in rows if r.ring == key])
    else:
        order = arch_order(rows, args.margin)
    print(f"sequence: {len(order)} steps, unique={len({t.tid for t in order})}")

    worst, failures = evaluate(rows, order, args.margin, verbose=True)
    print(f"  transitions over {args.margin}: {len(failures)}")
    for f in failures[:8]:
        print(f"    FAIL {f[0]}->{f[1]} {f[2]} |max|={f[3]:.3f}")

    cov, double, poles = coverage(rows, step=3.0)
    print(f"coverage: single={cov*100:.2f}% double={double*100:.2f}% "
          f"zenith_samples={poles['zenith']} nadir_samples={poles['nadir']}")

    ov = pair_overlaps(rows)
    thin = [v for v in ov if v[3] <= 60][-6:]
    print("  thinnest neighbour overlaps:")
    for o, a, b, sep in thin:
        print(f"    {a:>2}-{b:>2} sep={sep:5.1f}deg overlap={o*100:5.1f}%")

    ok = not failures and cov >= 0.9999 and poles["zenith"] and poles["nadir"]
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
