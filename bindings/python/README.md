# QULES for Python

Python package for the QULES derivative-free optimizer.

## Install

```sh
pip install pyqules
```

## Usage

```python
import pyqules

f = lambda x: (x[0] - 1)**2 + 10 * (x[1] + 2)**2
r = pyqules.optimize(f, [3.0, 1.0], max_evals=150)
r.x_best, r.f_best, r.evals
```

Options: `max_evals` (300), `delta0` (1.0), `delta_min` (1e-8), `delta_max`
(100.0), `verbose` (False), `rotation` (True).

Ask/tell interface:

```python
with pyqules.Session([3.0, 1.0], max_evals=150) as s:
    while (x := s.ask()) is not None:
        s.tell(f(x))
    r = s.best()
```

## Requirements

- Python 3.9+
- Windows x64
- Linux x86_64 or aarch64, glibc 2.28+, pip 20.3+
- macOS 11+, Apple silicon or Intel
