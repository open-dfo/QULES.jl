# QULES for Python

Python package for the QULES derivative-free optimizer. Python 3.9+ on
Windows x64, Linux x86_64 and aarch64 with glibc 2.28+ (RHEL/Rocky 8+, most
HPC clusters, Ubuntu 20.04+, Debian 11+), and macOS 11+ on Apple silicon and
Intel.

## Install

```sh
pip install qules
```

On Linux, pip 20.3 or newer is required (older pip reports "not a supported
wheel on this platform"). Older systems such as RHEL/Rocky 8 ship an older pip;
upgrade it first with `python -m pip install --upgrade pip`, preferably in a
virtual environment.

## Usage

```python
import qules

f = lambda x: (x[0] - 1)**2 + 10 * (x[1] + 2)**2
r = qules.optimize(f, [3.0, 1.0], max_evals=150)
r.x_best, r.f_best, r.evals
```

Options: `max_evals` (300), `delta0` (1.0), `delta_min` (1e-8), `delta_max`
(100.0), `verbose` (False), `rotation` (True).

Ask/tell interface:

```python
with qules.Session([3.0, 1.0], max_evals=150) as s:
    while (x := s.ask()) is not None:
        s.tell(f(x))
    r = s.best()
```

## Building the wheel

```sh
julia --startup-file=no --project=build build/build_library.jl
python bindings/python/build_wheel.py
```

The wheel is written to `bindings/python/dist/`. To test it, install it and run
`python bindings/python/tests/test_qules.py` and, before a release,
`python bindings/python/tests/test_stress.py` (about 15 minutes).
