# QULES for MATLAB

A MATLAB toolbox containing `+qules` and the QULES native bundle. It needs
MATLAB R2025a or later on Windows x64, Linux x86-64, or macOS (Intel or Apple
silicon). No Julia installation or C compiler is needed.

## Installation and usage

1. Download `qules-matlab-<platform>.mltbx` for your platform from the
   [latest MATLAB release](https://github.com/open-dfo/QULES.jl/releases).
2. Open the file in MATLAB (double-click it, or run
   `matlab.addons.install('qules-matlab-<platform>.mltbx')`).
3. Load QULES once per session and optimize:

```matlab
qules.load();

f = @(x) (x(1) - 1)^2 + 10 * (x(2) + 2)^2;
r = qules.optimize(f, [3; 1], 'max_evals', 150, 'verbose', true);
r.x_best, r.f_best, r.evals
```

`qules.load()` uses the bundle installed with the toolbox. To use another
bundle, pass its directory or set the `QULES_BUNDLE` environment variable. On
Linux and macOS the first call creates library links inside the toolbox
folder, so the toolbox must be installed in a writable location (the default
Add-Ons folder is). Set `verbose` to `true` to print the iteration table and
termination summary.

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

The MATLAB packages workflow installs each toolbox in a fresh MATLAB session
and runs `test_qules` through `qules.load()`. To test a local bundle:

```
matlab -batch "addpath('bindings/matlab', 'bindings/matlab/tests'); test_qules('C:\path\to\libqules'); test_stress('C:\path\to\libqules')"
```
