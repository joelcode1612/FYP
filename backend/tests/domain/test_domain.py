import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))

from sitewise.domain.ranking import rank


def test_rank_sorts_descending_by_score():
    items = [{"score": 1}, {"score": 5}, {"score": 3}]
    assert [x["score"] for x in rank(items)] == [5, 3, 1]


def test_rank_treats_missing_score_as_zero():
    items = [{"score": 2}, {}]
    assert [x.get("score", 0) for x in rank(items)] == [2, 0]
