"""
    optimize_qules(black_box, x_start; kwargs...)
    optimize_qules(black_box, x_start, config::QULESConfig)

Minimize a black-box function `black_box` starting from `x_start` using the
QULES diagonal-envelope trust-region algorithm.

Accepts either a `QULESConfig` struct or keyword arguments matching its fields
(e.g. `max_evals=200, Delta0=1.0, rotation=true`).

Returns the best and final iterates (`x_best`/`f_best`, `x_final`/`f_final`),
active `points`/`values`, `evals`, `Delta`, and `Q_frame`.
The frame is identity without rotation.
`termination_reason` identifies the stop condition; `termination_reasons`
lists both limits when the evaluation budget and radius limit coincide.
"""
function optimize_qules(black_box, x_start; kwargs...)
    return optimize_qules(black_box, x_start, QULESConfig(; kwargs...))
end

function optimize_qules(black_box, x_start, config::QULESConfig)

    n = length(x_start)
    n > 0 || throw(ArgumentError("x_start must be nonempty"))
    config.sample_capacity_factor >= 1 ||
        throw(ArgumentError("sample_capacity_factor must be at least 1"))
    target_points = config.rotation ? max(2n + 1, div(n * (n + 3), 2)) : 2n + 1
    max_points = config.sample_capacity_factor * target_points

    samples = SampleSet()

    x_curr = Float64.(x_start)
    f_curr = black_box(x_curr)
    if isnan(f_curr)
        f_curr = Inf
    end

    push!(samples.points, copy(x_curr))
    push!(samples.y, f_curr)

    Delta = config.Delta0

    evals = 1
    iter = 0
    stop_reason = nothing
    flat_range = nothing
    Q_frame = Matrix{Float64}(I, n, n)

    evals = initial_coordinate_sampling!(samples, black_box, x_curr, Delta,
                                         config.max_evals, evals)

    if config.verbose
        print_iteration_header(; io=config.log_io)
        print_iteration(samples, iter, evals, Delta, "init"; io=config.log_io)
    end

    while evals < config.max_evals && Delta > config.Delta_min
        iter += 1
        x_curr, f_curr = best_incumbent(samples, x_curr, f_curr)

        prune_points!(samples, x_curr, max_points, target_points)

        prep = prepare_sample_geometry!(samples, black_box, copy(x_curr),
                                        Delta, config, evals, iter)
        evals = prep.evals
        if !prep.certified
            if prep.stop_reason !== nothing && prep.stop_reason != "max_evals"
                stop_reason = prep.stop_reason
            end
            break
        end

        x_curr, f_curr = best_incumbent(samples, x_curr, f_curr)

        evals >= config.max_evals && break

        finite_y = [y for (p, y) in zip(samples.points, samples.y) if is_finite_sample(p, y)]
        y_max = maximum(finite_y)
        y_min = minimum(finite_y)
        if y_max - y_min <= 1e-14 * max(1.0, abs(y_min))
            stop_reason = "flat_line"
            flat_range = y_max - y_min
            config.verbose && print_iteration(samples, iter, evals, Delta, "flat_line_terminate"; io=config.log_io)
            break
        end

        res = solve_inner_problem(samples, x_curr, f_curr, Delta, config;
                                  V_ext=config.rotation ? Q_frame : nothing)

        if !res.valid
            Delta *= config.theta_fail
            if config.verbose
                print_iteration(samples, iter, evals, Delta, "inner_fail($(res.status))"; io=config.log_io)
                print_inner_failure(res.status, iter; io=config.log_io)
            end
            continue
        end

        x_next = res.xplus
        dup_idx = find_exact_sample_index(samples, x_next)
        if dup_idx > 0
            f_next = samples.y[dup_idx]
            is_new_point = false
        else
            f_next = black_box(x_next)
            if isnan(f_next)
                f_next = Inf
            end
            evals += 1
            is_new_point = true
        end

        # Update orientation from the existing samples and the trial evaluation.
        if config.rotation && n > 1 && isfinite(f_next)
            # Rebind the reassigned loop state so the closures below capture
            # plain locals instead of boxing x_curr/f_curr for the whole loop.
            let x_curr = x_curr, f_curr = f_curr
                valid_idx = [i for i in eachindex(samples.points)
                             if isfinite(samples.y[i]) && all(isfinite, samples.points[i]) && norm(samples.points[i] .- x_curr) > 0]
                S_mat = isempty(valid_idx) ? zeros(Float64, n, 0) :
                        reduce(hcat, [samples.points[i] .- x_curr for i in valid_idx])
                d_vec = Float64[samples.y[i] - f_curr for i in valid_idx]
                p_k = x_curr .- x_next

                Q_frame = orientation_update(Q_frame, p_k, S_mat, d_vec, f_next - f_curr)
            end
        end

        if is_new_point
            push!(samples.points, copy(x_next))
            push!(samples.y, f_next)
        end

        step_norm = norm(x_next .- x_curr)
        actual_reduction = f_next - f_curr

        Delta, status, accepted = update_trust_region(
            Delta, step_norm, actual_reduction, res.pred_dec, config)

        if accepted
            x_curr = copy(x_next)
            f_curr = f_next
            prune_far_points!(samples, x_curr, Delta, config.rho_prune, target_points)
        elseif is_new_point
            replace_farthest_old_point!(samples, x_curr, target_points)
        end
        prune_points!(samples, x_curr, max_points, target_points)
        config.verbose && print_iteration(samples, iter, evals, Delta, status; io=config.log_io)

    end

    best_idx = best_sample_index(samples)
    reasons = termination_reasons(evals, Delta, config; reason=stop_reason)
    if config.verbose
        print_termination(samples, evals, Delta, config, reasons;
                          function_value_range=flat_range, io=config.log_io)
        flush(config.log_io)
    end

    return (
        x_best = samples.points[best_idx],
        f_best = samples.y[best_idx],
        x_final = x_curr,
        f_final = f_curr,
        points = samples.points,
        values = samples.y,
        evals = evals,
        Delta = Delta,
        Q_frame = Q_frame,
        termination_reason = first(reasons),
        termination_reasons = reasons
    )
end

"""
    best_incumbent(samples, x_curr, f_curr)

Return the best sample and its value if it strictly improves on `f_curr`,
otherwise `(x_curr, f_curr)`. This keeps every `δ_i = y_i - f_curr` nonnegative.
"""
function best_incumbent(samples::SampleSet, x_curr, f_curr)
    best_idx = best_sample_index(samples)
    if best_idx > 0 && samples.y[best_idx] < f_curr
        return copy(samples.points[best_idx]), samples.y[best_idx]
    end
    return x_curr, f_curr
end

"""
    termination_reasons(evals, Delta, config; reason=nothing)

Return the list of stop conditions met: an explicit `reason`, otherwise
`"max_evals"` and/or `"delta_min"`, or `["stopped"]` if neither applies.
"""
function termination_reasons(evals, Delta, config; reason=nothing)
    reason !== nothing && return [reason]
    reasons = String[]
    evals >= config.max_evals && push!(reasons, "max_evals")
    Delta <= config.Delta_min && push!(reasons, "delta_min")
    return isempty(reasons) ? ["stopped"] : reasons
end
