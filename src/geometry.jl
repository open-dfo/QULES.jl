"""
    weighted_displacement!(z, point, a, Delta)

Write the weighted displacement `w (point - a) / Delta` into `z`, where
`w = Delta^2 / (Delta^2 + ‖point - a‖^2)`. Intermediate scaling by
`max(Delta, ‖point - a‖_∞)` only improves conditioning; the result is unchanged.
"""
function weighted_displacement!(z, point, a, Delta)
    z .= point .- a
    scale = max(Delta, maximum(abs, z; init=0.0))
    z ./= scale
    radius = Delta / scale
    z .*= radius / (radius^2 + dot(z, z))
    return z
end

"""
    build_weighted_svd(samples, a, Delta; spare_columns=0)

Assemble the weighted displacement matrix `Z` of the finite samples about `a`
and return `(Z, F, m0)` with `F = svd(Z)` and `m0` the number of columns used.
`spare_columns` preallocates room for points added during repair.
"""
function build_weighted_svd(samples::SampleSet, a::Vector{Float64}, Delta::Float64;
                            spare_columns::Int=0)
    n = length(a)
    m0 = count(i -> is_finite_sample(samples.points[i], samples.y[i]),
               eachindex(samples.points))
    Z = Matrix{Float64}(undef, n, m0 + spare_columns)
    column = 0
    for (point, y) in zip(samples.points, samples.y)
        is_finite_sample(point, y) || continue
        column += 1
        weighted_displacement!(@view(Z[:, column]), point, a, Delta)
    end
    F = svd(@view(Z[:, 1:m0]); full=m0 < n)
    return (Z=Z, F=F, m0=m0)
end

"""
    least_represented_direction(samples, x_current, Delta=1.0)

Return a unit vector in the least represented sample direction of the
weighted displacement matrix at radius `Delta`.
"""
function least_represented_direction(samples::SampleSet, x_current, Delta::Real=1.0)
    n = length(x_current)
    n > 0 || return zeros(n)
    state = build_weighted_svd(samples, Float64.(x_current), Float64(Delta))
    u = state.F.U[:, end]
    return u ./ norm(u)
end

"""
    sample_geometry_ok(samples, x_current, Delta, sigma_s)

Return whether `σ_min(Z) ≥ sigma_s` for the weighted displacement matrix `Z`
about `x_current` at radius `Delta`.
"""
function sample_geometry_ok(samples::SampleSet, x_current, Delta, sigma_s)
    isempty(samples.points) && return false
    n = length(x_current)
    n == 0 && return true
    state = build_weighted_svd(samples, Float64.(x_current), Float64(Delta))
    state.m0 < n && return false
    return state.F.S[end] >= Float64(sigma_s)
end

"""
    prepare_sample_geometry!(samples, black_box, a, Delta, config, evals, iter)

Enforce the weighted geometry condition `σ_min(Z) ≥ sigma_s` about the fixed
reference `a`. While it fails, evaluate `a + Delta*u` (or `a - Delta*u` if that
point is already sampled) along the least represented direction `u` and append
it; at most `n` points are added. Return `(certified, evals, stop_reason)`.
"""
function prepare_sample_geometry!(samples::SampleSet, black_box, a::Vector{Float64},
                                  Delta::Float64, config::QULESConfig,
                                  evals::Int, iter::Int)
    n = length(a)
    n == 0 && return (certified=true, evals=evals, stop_reason=nothing)

    state = build_weighted_svd(samples, a, Delta; spare_columns=n)
    state.m0 == 0 && return (certified=false, evals=evals, stop_reason="nonfinite_geometry")
    Z = state.Z
    F = state.F
    ncols = state.m0
    sigma_min = ncols < n ? 0.0 : F.S[end]

    ops = 0
    while sigma_min < config.sigma_s
        ops >= n && return (certified=false, evals=evals, stop_reason="geometry_stall")

        u = F.U[:, end]
        u ./= norm(u)

        xp = a .+ Delta .* u
        xm = a .- Delta .* u

        evals >= config.max_evals && return (certified=false, evals=evals, stop_reason="max_evals")

        added_finite = false
        represented = false
        for x_cand in (xp, xm)
            # Δu can be absorbed by roundoff when |a| ≫ Δ; such a candidate is not a new point.
            x_cand == a && continue
            represented = true
            existing_idx = find_exact_sample_index(samples, x_cand)
            if existing_idx > 0
                continue
            end
            evals >= config.max_evals && return (certified=false, evals=evals, stop_reason="max_evals")

            f_new = black_box(x_cand)
            if isnan(f_new)
                f_new = Inf
            end
            push!(samples.points, x_cand)
            push!(samples.y, f_new)
            evals += 1
            config.verbose && print_iteration(samples, iter, evals, Delta, "geometry"; io=config.log_io)

            if is_finite_sample(x_cand, f_new)
                ncols += 1
                weighted_displacement!(@view(Z[:, ncols]), x_cand, a, Delta)
                F = svd(@view(Z[:, 1:ncols]); full=ncols < n)
                sigma_min = ncols < n ? 0.0 : F.S[end]
                ops += 1
                added_finite = true
                break
            end
        end

        if !added_finite
            reason = represented ? "nonfinite_geometry" : "geometry_stall"
            return (certified=false, evals=evals, stop_reason=reason)
        end
    end

    return (certified=true, evals=evals, stop_reason=nothing)
end
