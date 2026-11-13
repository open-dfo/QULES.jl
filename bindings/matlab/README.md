# QULES for MATLAB

MATLAB package `+qules` for the QULES native bundle. Windows x64; no compiler
needed.

## Usage

```matlab
addpath('bindings/matlab');
qules.load('C:\path\to\libqules');

f = @(x) (x(1) - 1)^2 + 10 * (x(2) + 2)^2;
r = qules.optimize(f, [3; 1], 'max_evals', 150);
r.x_best, r.f_best, r.evals
```

Options (name-value pairs or a struct): `max_evals` (300), `delta0` (1.0),
`delta_min` (1e-8), `delta_max` (100.0), `verbose` (false), `rotation` (true).

Ask/tell interface:

```matlab
s = qules.Session([3; 1], 'max_evals', 150);
while true
    x = s.ask();  if isempty(x), break, end
    s.tell(f(x));
end
r = s.best();
```

## Test

```
matlab -batch "addpath('bindings/matlab'); addpath('bindings/matlab/tests'); test_qules('C:\path\to\libqules')"
```
