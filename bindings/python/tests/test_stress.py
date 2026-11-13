"""Run the compiled bundle through many problem types and every stop condition.

    python tests/test_stress.py [bundle_dir]

Each case runs with and without verbose output, through `optimize` and
`Session`. A native failure in any of them means the bundle lacks a code path.
"""

import math
import sys
import time
import traceback

try:
    import qules
except ImportError:  # running from a source checkout without installing
    import os
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    import qules

MESSAGES = {
    "max_evals": "Evaluation budget reached",
    "delta_min": "Trust-region radius reached its minimum",
    "flat_line": "Active sample function values are flat",
    "geometry_stall": "Sample geometry could not be repaired",
    "nonfinite_geometry": "Geometry repair produced only nonfinite values",
    "inner_failure": "WARNING [iter=",
}


def quadratic(x):
    return sum((i + 1) * (v - 1.0) ** 2 for i, v in enumerate(x))


def rotated_ill(x):
    s = sum(x)
    return (s - 1.0) ** 2 + 1e4 * sum((x[i] - x[i + 1]) ** 2 for i in range(len(x) - 1))


def rosenbrock(x):
    return sum(100.0 * (x[i + 1] - x[i] ** 2) ** 2 + (1.0 - x[i]) ** 2 for i in range(len(x) - 1))


def nonsmooth(x):
    return sum(abs(v - 0.3) for v in x)


def camel(x):
    return 2 * x[0] ** 2 - 1.05 * x[0] ** 4 + x[0] ** 6 / 6 + x[0] * x[1] + x[1] ** 2


def nan_region(x):
    return math.nan if x[0] > 2.5 else quadratic(x)


def inf_region(x):
    return math.inf if sum(x) < -1.0 else quadratic(x)


def huge_scale(x):
    return 1e12 * quadratic(x)


def flat(x):
    return 1.0


def only_start_finite(x):
    return 0.0 if all(v == 0.0 for v in x) else math.nan


def case(name, f, x0, **options):
    return name, f, list(x0), options


CASES = [
    *(case(f"quadratic n={n}", quadratic, [3.0] * n, max_evals=150) for n in (1, 2, 5, 10)),
    case("quadratic n=20", quadratic, [3.0] * 20, max_evals=120),
    *(case(f"rotated ill-conditioned n={n}", rotated_ill, [2.0] + [-1.0] * (n - 1), max_evals=150)
      for n in (2, 5)),
    case("rosenbrock n=3", rosenbrock, [-1.2, 1.0, 0.5], max_evals=200),
    case("nonsmooth n=4", nonsmooth, [2.0, -1.0, 0.0, 1.0], max_evals=150),
    case("three-hump camel", camel, [-1.0, 2.0], max_evals=100),
    case("NaN region", nan_region, [3.0, 1.0], max_evals=100),
    case("Inf region", inf_region, [-0.5, -0.4], max_evals=100),
    case("huge values", huge_scale, [3.0, 1.0], max_evals=100),
    case("tiny start radius", quadratic, [3.0, 1.0], max_evals=100, delta0=1e-6),
    case("large delta_min", quadratic, [3.0, 1.0], max_evals=300, delta_min=1e-2),
    case("budget 1", quadratic, [3.0, 1.0], max_evals=1),
    case("budget 2", quadratic, [3.0, 1.0], max_evals=2),
    case("flat values", flat, [0.5, 0.5], max_evals=50),
    case("unrepresentable start", quadratic, [1e20], max_evals=20),
    case("nonfinite geometry", only_start_finite, [0.0, 0.0], max_evals=20),
]


def run_session(f, x0, **options):
    with qules.Session(x0, **options) as s:
        while (x := s.ask()) is not None:
            s.tell(f(x))
        return s.best()


def check(name, result, options, finite_expected):
    assert result.evals <= options.get("max_evals", 300), f"{name}: {result.evals} evals"
    assert len(result.x_best) > 0
    if finite_expected:
        assert math.isfinite(result.f_best), f"{name}: f_best {result.f_best}"


def main(argv):
    if len(argv) > 2:
        print(f"usage: {argv[0]} [bundle_dir]", file=sys.stderr)
        return 2
    qules.load(argv[1] if len(argv) == 2 else None)
    print("QULES version", ".".join(map(str, qules.version())))

    seen = {key: [] for key in MESSAGES}
    failed = 0
    runs = 0
    for name, f, x0, options in CASES:
        finite_expected = f is not only_start_finite
        for rotation in (True, False):
            label = f"{name} (rotation={rotation})"
            start = time.perf_counter()
            try:
                opts = dict(options, rotation=rotation)
                quiet = qules.optimize(f, x0, **opts)
                lines = []
                loud = qules.optimize(f, x0, verbose=True, log=lines.append, **opts)
                session = run_session(f, x0, verbose=True, log=lambda _line: None, **opts)
                runs += 3
                for r in (quiet, loud, session):
                    check(label, r, opts, finite_expected)
                assert loud.x_best == quiet.x_best and session.x_best == quiet.x_best, \
                    f"{label}: verbose or session run differs from the quiet run"
                assert any(line.startswith("Termination") for line in lines), \
                    f"{label}: no Termination line"
                text = "\n".join(lines)
                for key, message in MESSAGES.items():
                    if message in text:
                        seen[key].append(label)
                print(f"PASS {label:45s} f_best={quiet.f_best:<12.4e} evals={quiet.evals:<4d} "
                      f"{time.perf_counter() - start:5.1f}s")
            except Exception:
                failed += 1
                print(f"FAIL {label}")
                traceback.print_exc()

    print("\nStop conditions and warnings reached:")
    for key, labels in seen.items():
        print(f"  {key:20s} {len(labels):3d} run(s)")
        if not labels:
            failed += 1
            print(f"FAIL no case reached {key}")
    print(f"\n{runs} native runs, {failed} failure(s)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
