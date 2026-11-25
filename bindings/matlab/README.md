# QULES for MATLAB

The QULES toolbox runs on MATLAB R2025a or later on Windows x64, Linux x86-64,
and macOS (Intel or Apple silicon). No Julia installation or C compiler is
needed.

## Installation and usage

1. In MATLAB, open **Home → Add-Ons → Get Add-Ons**, search for **QULES** and
   click **Add**. The toolbox is also on
   [File Exchange](https://www.mathworks.com/matlabcentral/fileexchange/185309-qules).
   Alternatively, download `QULES.mltbx` from the
   [latest release](https://github.com/open-dfo/QULES.jl/releases/latest) and
   open it in MATLAB.
2. Load QULES once per session and optimize:

```matlab
qules.load();

f = @(x) (x(1) - 1)^2 + 10 * (x(2) + 2)^2;
r = qules.optimize(f, [3; 1], 'max_evals', 150, 'verbose', true);
r.x_best, r.f_best, r.evals
```

The first `qules.load()` downloads the QULES native library for your platform
(about 80 MB) from the project's GitHub release, checks its SHA-256 and installs it in
`%LOCALAPPDATA%\qules\matlab` on Windows or `~/.qules/matlab` on Linux and
macOS. Later sessions use the installed copy. Set `verbose` to `true` to print
the iteration table and termination summary.

Without internet access, download `qules-bundle-<platform>.zip` from the
[release](https://github.com/open-dfo/QULES.jl/releases/latest) on another
machine and install it with `qules.install_bundle('qules-bundle-<platform>.zip')`.
On a cluster with a shared home directory, one `qules.load()` on a login node
installs the library for the compute nodes. To use another bundle, pass its
directory to `qules.load` or set the `QULES_BUNDLE` environment variable.

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

On each platform the MATLAB packages workflow installs that platform's bundle
archive with `qules.install_bundle` and runs `test_qules` through
`qules.load()`. It then installs the assembled `QULES.mltbx` on Linux and
repeats the test in a fresh MATLAB session. To test a local bundle:

```
matlab -batch "addpath('bindings/matlab', 'bindings/matlab/tests'); test_qules('C:\path\to\libqules'); test_stress('C:\path\to\libqules')"
```
