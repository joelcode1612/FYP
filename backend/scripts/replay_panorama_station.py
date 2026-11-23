"""Replay a frozen device station into a new directory without accessing storage or SQL."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from sitewise.panorama.stitcher import stitch_equirectangular


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("station", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, choices=(2048, 4096), default=2048)
    parser.add_argument("--vertical-fov", type=float, default=65.0)
    args = parser.parse_args()
    root = args.station.resolve()
    output = args.output.resolve()
    if output.is_relative_to(root) or not 0 < args.vertical_fov < 180:
        parser.error("Choose a separate output directory and a vertical FOV between 0 and 180 degrees.")
    checksums = json.loads((root / "sha256.json").read_text())

    def verified(path: Path) -> bytes:
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != checksums[path.relative_to(root).as_posix()]:
            raise ValueError(f"Checksum mismatch for {path.name}")
        return data

    records = json.loads(verified(root / "records.json"))
    if sorted(row["targetId"] for row in records) != list(range(1, 39)):
        parser.error("Expected exactly one frame for each of the 38 targets.")
    paths = set()
    for row in records:
        path = root / "frames" / Path(row["imagePath"]).name
        verified(path)
        paths.add(path)
        row["imagePath"] = str(path)
    if len(paths) != 38:
        parser.error("Each target needs its own source file.")
    output.mkdir(parents=True, exist_ok=False)
    result = stitch_equirectangular(
        records=records,
        out_dir=output,
        width=args.width,
        vertical_fov_deg=args.vertical_fov,
        strict_photo_coverage=True,
        progress=lambda stage: print(stage, flush=True),
    )
    print(result.message)
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
