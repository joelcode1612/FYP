"""Regression checks for panorama owner boundaries and RGB discontinuity."""
import numpy as np

from sitewise.panorama.seam_blend import _output_delta, composite_seams


def test_uniform_owner_has_no_seam():
    width, height = 16, 8
    size = width * height
    colors = np.zeros(size * 3, dtype=np.uint8)
    owners = np.zeros(size, dtype=np.int16)
    stats = composite_seams(
        output=colors.copy(),
        width=width,
        height=height,
        best_colour=colors,
        second_colour=colors,
        best_weight=np.ones(size, dtype=np.float32),
        second_weight=np.full(size, 0.1, dtype=np.float32),
        best_frame=owners,
        second_frame=owners + 1,
        channel_gains=[1.0] * 6,
        min_weight=0.0001,
    )
    assert stats.seam_pixels == 0


def test_rgb_difference_is_symmetric():
    pixels = np.array([0, 0, 0, 4, 8, 12], dtype=np.uint8)
    first, second = np.array([0]), np.array([1])
    assert _output_delta(pixels, first, second)[0] == 8
    assert _output_delta(pixels, second, first)[0] == 8
