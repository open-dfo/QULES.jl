# QULES for Python

Python binding for the QULES native bundle. Windows x64, Python 3.9+.

## Install

```sh
pip install ./bindings/python
```

## Usage

```python
import qules
qules.load(r"C:\path\to\libqules")

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

## Test

```sh
python bindings/python/tests/test_qules.py C:\path\to\libqules
```
