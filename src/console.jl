function print_iteration_header(; io=stdout)
    @printf(io, "%7s %7s %16s %12s %7s  %-18s\n",
            "Iter", "Eval", "Best f", "Delta", "Points", "Status")
    println(io, repeat('-', 73))
end

function iteration_status_label(status)
    startswith(status, "inner_fail(") && return "inner failed"
    status == "init" && return "initialized"
    status == "geometry" && return "geometry"
    status == "success_expand" && return "accepted, expand"
    status == "success_shrink" && return "accepted, shrink"
    status == "fail" && return "rejected"
    status == "flat_line_terminate" && return "flat values"
    return status
end

function print_iteration(samples, iter, evals, Delta, status; io=stdout)
    @printf(io, "%7d %7d %16.8e %12.4e %7d  %-18s\n",
            iter, evals, minimum(samples.y; init=Inf), Delta, length(samples.points),
            iteration_status_label(status))
end

function print_inner_failure(status, iter; io=stdout)
    message = if status == MOI.ITERATION_LIMIT
        "Inner solver reached its iteration limit."
    elseif status == MOI.TIME_LIMIT
        "Inner solver reached its time limit."
    elseif status == MOI.LOCALLY_INFEASIBLE
        "Inner solver could not find a locally feasible envelope solution."
    elseif status == MOI.INFEASIBLE
        "Inner solver reported envelope-model infeasibility."
    elseif status == MOI.NUMERICAL_ERROR
        "Inner solver encountered a numerical error."
    elseif status == MOI.INVALID_MODEL
        "Too few finite samples to build the inner model."
    else
        "Inner solver did not return a valid solution."
    end
    @printf(io, "  WARNING [iter=%d] (%s): %s\n", iter, string(status), message)
end

function termination_message(reason::AbstractString)
    reason == "max_evals" && return "Evaluation budget reached"
    reason == "delta_min" && return "Trust-region radius reached its minimum"
    reason == "flat_line" && return "Active sample function values are flat"
    reason == "geometry_stall" && return "Sample geometry could not be repaired"
    reason == "nonfinite_geometry" && return "Geometry repair produced only nonfinite values"
    reason == "stopped" && return "Optimization stopped"
    return reason
end

function print_termination(samples, evals, Delta, config, reasons;
                           function_value_range=nothing, io=stdout)
    println(io, repeat('-', 73))
    @printf(io, "%-12s : %s\n", "Termination", join(termination_message.(reasons), "; "))
    @printf(io, "%-12s : %d / %d\n", "Evaluations", evals, config.max_evals)
    @printf(io, "%-12s : %.8e\n", "Best f", minimum(samples.y; init=Inf))
    @printf(io, "%-12s : %.4e\n", "Final Delta", Delta)
    if function_value_range !== nothing
        @printf(io, "%-12s : %.4e\n", "Value range", function_value_range)
    end
end
