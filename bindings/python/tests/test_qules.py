"""Smoke tests for the QULES Python binding.

Standalone (standard library only):

    python tests/test_qules.py C:\\path\\to\\bundle

Under pytest, with the bundle directory in the QULES_BUNDLE environment variable:

    pytest tests

Exits non-zero if any check fails.
"""

import math
import os
import sys
import traceback

try:
    import qules
except ImportError:  # running from a source checkout without installing
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import qules


def quadratic(x):
    return (x[0] - 1.0) ** 2 + 10.0 * (x[1] + 2.0) ** 2


def rosenbrock(x):
    return sum(100.0 * (x[i + 1] - x[i] ** 2) ** 2 + (1.0 - x[i]) ** 2 for i in range(len(x) - 1))


class Boom(Exception):
    pass


def run_session(f, x0, **options):
    """Drive a Session to completion; returns (Result, number of asks)."""
    asks = 0
    with qules.Session(x0, **options) as s:
        while (x := s.ask()) is not None:
            asks += 1
            s.tell(f(x))
        assert s.finished(), "session not finished after ask() returned None"
        return s.best(), asks


def check_quadratic(result, evals):
    assert result.evals == evals, f"evals {result.evals} != {evals}"
    assert result.f_best < 1e-12, f"f_best {result.f_best} not < 1e-12"
    assert abs(result.x_best[0] - 1.0) < 1e-5, f"x1 {result.x_best[0]}"
    assert abs(result.x_best[1] + 2.0) < 1e-5, f"x2 {result.x_best[1]}"


def setup_module(module=None):
    """pytest hook: load the bundle named by QULES_BUNDLE (main() loads from argv)."""
    qules.load()


def test_quadratic():
    for rotation in (True, False):
        r = qules.optimize(quadratic, [3.0, 1.0], max_evals=40, rotation=rotation)
        check_quadratic(r, 40)
        s, asks = run_session(quadratic, [3.0, 1.0], max_evals=40, rotation=rotation)
        check_quadratic(s, 40)
        assert asks == 40, f"session asked {asks} times"
        # Same algorithm, same inputs: ask/tell must reproduce optimize() exactly.
        assert s.x_best == r.x_best, f"session x_best {s.x_best} != {r.x_best} (rotation={rotation})"
        assert s.f_best == r.f_best, f"session f_best {s.f_best} != {r.f_best} (rotation={rotation})"
        assert s.evals == r.evals


def test_rosenbrock():
    x0 = [-1.2, 1.0, 0.5]
    r = qules.optimize(rosenbrock, x0, max_evals=80)
    assert r.evals == 80 and math.isfinite(r.f_best), r
    assert len(r.x_best) == 3
    s, _ = run_session(rosenbrock, x0, max_evals=80)
    assert s.evals == 80 and math.isfinite(s.f_best), s


def test_verbose_optimize():
    lines = []
    r = qules.optimize(quadratic, [3.0, 1.0], max_evals=40, verbose=True, log=lines.append)
    check_quadratic(r, 40)
    assert any("Termination" in line for line in lines), f"no Termination line in {lines!r}"
    assert all(not line.endswith("\n") for line in lines)


def test_verbose_session():
    lines = []
    s, _ = run_session(quadratic, [3.0, 1.0], max_evals=40, verbose=True, log=lines.append)
    check_quadratic(s, 40)
    assert any("Termination" in line for line in lines), f"no Termination line in {lines!r}"


def test_session_delta_nan_until_finished():
    with qules.Session([3.0, 1.0], max_evals=40) as s:
        x = s.ask()
        s.tell(quadratic(x))
        assert math.isnan(s.best().delta), "delta must be NaN before the session finishes"
        while (x := s.ask()) is not None:
            s.tell(quadratic(x))
        assert math.isfinite(s.best().delta)


def test_objective_exception():
    calls = 0

    def bad(x):
        nonlocal calls
        calls += 1
        if calls == 3:
            raise Boom("objective failed")
        return quadratic(x)

    try:
        qules.optimize(bad, [3.0, 1.0], max_evals=40)
    except Boom as exc:
        assert str(exc) == "objective failed"
    else:
        raise AssertionError("exception inside the objective was not propagated")
    # The library must still be usable afterwards.
    check_quadratic(qules.optimize(quadratic, [3.0, 1.0], max_evals=40), 40)


def test_bad_arguments():
    try:
        qules.optimize(quadratic, [], max_evals=40)
    except ValueError:
        pass
    else:
        raise AssertionError("empty x0 accepted")


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <bundle_dir>", file=sys.stderr)
        return 2
    qules.load(argv[1])
    print("QULES version", ".".join(map(str, qules.version())))
    tests = [fn for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"PASS {test.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL {test.__name__}")
            traceback.print_exc()
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
