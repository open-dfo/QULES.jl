# QULES for MATLAB

The MATLAB package includes `+qules` and the QULES native bundle. The package
workflow targets MATLAB R2025a on Windows x64, Linux x86-64, and macOS on Intel and
Apple silicon.

## Installation and usage

1. Download the artifact named `qules-matlab-<platform>` from a successful
   [MATLAB packages workflow run](https://github.com/open-dfo/QULES.jl/actions/workflows/matlab-probe.yml).
2. Unzip the artifact and extract the enclosed `.tar.gz` with a tool that
   preserves symbolic links, such as `tar -xzf`.
3. Set MATLAB's current folder to the extracted directory that contains
   `+qules` and `libqules`, then run the following example.

```matlab
addpath(pwd);
qules.load(fullfile(pwd, 'libqules'));

f = @(x) (x(1) - 1)^2 + 10 * (x(2) + 2)^2;
r = qules.optimize(f, [3; 1], 'max_evals', 150, 'verbose', true);
r.x_best, r.f_best, r.evals
```

The archive contains the files required by `qules.load`, including MATLAB's
platform-specific loader files. Set `verbose` to `true` to print the iteration
table and termination summary.

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

The workflow extracts each archive and runs `test_qules` and `test_stress`
through the packaged `qules.load` entry point in a fresh MATLAB session.
