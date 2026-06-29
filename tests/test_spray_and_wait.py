from routing.spray_and_wait import SprayBudgetTracker, is_wait_phase, split_copies


def test_even_l_splits_in_half():
    copies = split_copies(8)
    assert copies.forward == 4
    assert copies.keep == 4


def test_odd_l_keep_gets_the_extra_copy():
    copies = split_copies(5)
    assert copies.forward == 2
    assert copies.keep == 3


def test_l_one_keeps_the_only_copy():
    copies = split_copies(1)
    assert copies.forward == 0
    assert copies.keep == 1


def test_l_zero_sprays_nothing_further():
    copies = split_copies(0)
    assert copies.forward == 0
    assert copies.keep == 0


def test_wait_phase_starts_at_l_one():
    assert is_wait_phase(1) is True
    assert is_wait_phase(0) is True
    assert is_wait_phase(2) is False


def test_budget_tracker_accepts_first_sighting():
    tracker = SprayBudgetTracker()
    assert tracker.check(b"msg-1", 8) is None


def test_budget_tracker_accepts_equal_or_lower_l():
    tracker = SprayBudgetTracker()
    tracker.check(b"msg-1", 8)
    assert tracker.check(b"msg-1", 4) is None
    assert tracker.check(b"msg-1", 4) is None


def test_budget_tracker_rejects_inflated_l():
    tracker = SprayBudgetTracker()
    tracker.check(b"msg-1", 8)
    reason = tracker.check(b"msg-1", 16)
    assert reason is not None
    assert "inflated" in reason.lower()
