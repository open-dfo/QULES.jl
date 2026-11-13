# Representative Julia API calls reduce first-use compilation.
# Native callback, session, and logging workloads live in build/precompile_library.jl.
@setup_workload begin
    let
        quadratic = x -> (x[1] - 1.0)^2 + 10.0 * (x[2] + 2.0)^2
        rosenbrock = x -> sum(
            100.0 * (x[i + 1] - x[i]^2)^2 + (1.0 - x[i])^2
            for i in 1:(length(x) - 1)
        )
        cases = (
            (quadratic, [3.0, 1.0], 8),
            (rosenbrock, [-1.2, 1.0, 0.5], 80),
        )
        @compile_workload begin
            for (objective, x_start, max_evals) in cases, rotation in (true, false)
                optimize_qules(objective, x_start;
                               max_evals=max_evals, rotation=rotation, verbose=false)
                optimize_qules(objective, x_start;
                               max_evals=max_evals, rotation=rotation,
                               verbose=true, log_io=IOBuffer())
            end
        end
    end
end
