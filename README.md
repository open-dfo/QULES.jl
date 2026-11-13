# QULES.jl

QULES is a Julia solver for unconstrained derivative-free optimization.
It minimizes black-box objective functions using diagonal quadratic envelopes
within a trust-region framework.

## Installation

Requires Julia 1.10 or later. From the repository directory:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

## Usage

```julia
using QULES

f(x) = (x[1] - 1.0)^2 + 10.0 * (x[2] + 2.0)^2

result = optimize_qules(
    f, [3.0, 1.0];
    max_evals = 150,
    Delta0 = 1.0,
    verbose = false,
)

@show result.x_best result.f_best result.evals
```

### Options

Pass these options as keywords to `optimize_qules`:

| Parameter | Default | Meaning |
| --- | --- | --- |
| `max_evals` | `300` | Objective evaluation budget |
| `Delta0` | `1.0` | Initial trust-region radius |
| `Delta_min` | `1e-8` | Stop when the radius reaches this value |
| `Delta_max` | `100.0` | Largest trust-region radius |
| `rotation` | `true` | Learn the envelope orientation; `false` keeps coordinate axes |
| `verbose` | `true` | Print iteration output |
| `inner_optimizer` | `nothing` | JuMP optimizer for the inner problem; `nothing` uses Ipopt |

The remaining algorithm parameters and their defaults are listed in
`QULESConfig` (`src/types.jl`).

## Rotation

By default, `rotation=true` learns the envelope orientation from existing
objective evaluations using pairwise Jacobi updates. The orientation update
makes no additional objective calls. Set `rotation=false` to keep
coordinate-aligned axes. `result.Q_frame` contains the frame axes as columns.

```julia
f_rotated(x) = (x[1] + x[2])^2 + 10.0 * (x[1] - x[2])^2

result = optimize_qules(
    f_rotated, [3.0, 1.0];
    max_evals = 150,
    rotation = true,
    verbose = false,
)

@show result.x_best result.f_best result.Q_frame
```

## Inner optimizer settings

Ipopt is the default inner optimizer. Pass `inner_optimizer=KNITRO.Optimizer`
to use Knitro with its default options. To supply custom settings, use JuMP's
`optimizer_with_attributes`:

```julia
using QULES, JuMP, KNITRO

knitro = optimizer_with_attributes(
    KNITRO.Optimizer,
    "outlev" => 0,
    "maxit" => 1000,
    "feastol" => 1e-8,
)

result = optimize_qules(
    f, [3.0, 1.0];
    inner_optimizer = knitro,
    max_evals = 150,
    verbose = false,
)
```

## Other languages

QULES can be compiled into a native Windows x64 library and called from C, C++,
Python and MATLAB. Build the library bundle from the repository root:

```sh
julia --startup-file=no --project=build build/build_library.jl
```

This writes `build/libqules/`; pass that directory to the binding. Each binding
has its own README:

| Language | Directory |
| --- | --- |
| C | [`bindings/c`](bindings/c) |
| C++ | [`bindings/cpp`](bindings/cpp) |
| Python | [`bindings/python`](bindings/python) |
| MATLAB | [`bindings/matlab`](bindings/matlab) |

