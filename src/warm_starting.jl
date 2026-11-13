"""
    build_start_p_alpha_beta(S, δ, M, Delta; tol=1e-12)

Use only the current sample displacements and value differences. Compare
feasible zero, centroid, and sample-based steps by gap. At best-sample centers,
also compare their opposite directions. Curvature bounds are sign-aware.
The final zero-step fallback may be infeasible.
"""
function build_start_p_alpha_beta(S, δ, M, Delta; tol=1e-12)
    n = size(M, 1)
    best_center = all(d -> d >= 0.0, δ)

    p_candidates = Vector{Vector{Float64}}()
    push!(p_candidates, zeros(n))
    order = sortperm(δ)
    n_best = min(3, length(order))
    if n_best > 1
        p_centroid = zeros(n)
        for i in 1:n_best
            p_centroid .-= S[order[i]]
        end
        p_centroid ./= n_best
        p_centroid = project_p_to_tr(p_centroid, M, 0.999 * Delta)
        if norm(p_centroid) > tol
            push!(p_candidates, p_centroid)
            best_center && push!(p_candidates, -p_centroid)
        end
    end
    for idx in order
        p0 = -S[idx]
        if norm(p0) > tol
            p0 = project_p_to_tr(p0, M, 0.999 * Delta)
            push!(p_candidates, p0)
            best_center && push!(p_candidates, -p0)
        end
    end

    best = nothing
    for p0 in p_candidates
        curvatures = scalar_start_curvatures(S, δ, p0)
        curvatures === nothing && continue
        A, B = curvatures
        if best === nothing || B - A < best[1]
            best = (B - A, p0, A, B)
        end
    end
    if best !== nothing
        _, p0, A, B = best
        return p0, fill(A, n), fill(B, n)
    end
    return zeros(n), fill(1e-12, n), fill(1e-12, n)
end

"""
    scalar_start_curvatures(S, δ, p0)

For a fixed step `p0`, return scalar curvatures `(A, B)` such that the
envelopes with `α ≡ A`, `β ≡ B` satisfy all sampled constraints, or `nothing`
if no such pair exists. `B` is the smallest feasible upper curvature and `A`
the largest feasible lower curvature, each relaxed by a constant factor.
"""
function scalar_start_curvatures(S, δ, p0)
    curvature_min = 1e-12
    P = dot(p0, p0)
    B_low = curvature_min
    B_high = Inf

    for i in eachindex(S)
        si = S[i]
        coefficient = dot(p0, si) + 0.5 * dot(si, si)
        if coefficient > 0.0
            B_low = max(B_low, δ[i] / coefficient)
        elseif coefficient < 0.0
            B_high = min(B_high, δ[i] / coefficient)
        elseif δ[i] > 0.0
            return nothing
        end

        C = sum((si[j] + p0[j])^2 for j in eachindex(p0))
        if P > 0.0
            B_low = max(B_low, (curvature_min * C - 2.0 * δ[i]) / P)
        elseif δ[i] < 0.5 * curvature_min * C
            return nothing
        end
    end
    if !isfinite(B_low) || B_low > B_high
        return nothing
    end

    # One representable increment protects active lower bounds from rounding.
    B = min(nextfloat(B_low), B_high)
    Amax = B
    for i in eachindex(S)
        si = S[i]
        C = sum((si[j] + p0[j])^2 for j in eachindex(p0))
        if C > 0.0
            Amax = min(Amax, (2.0 * δ[i] + B * P) / C)
        end
    end
    if !isfinite(B) || Amax < curvature_min
        return nothing
    end
    return max(curvature_min, 0.75 * Amax), 1.5 * B
end

"""
    project_p_to_tr(p, M, Delta)

Scale `p` onto the trust region `p' * M * p <= Delta^2` if it lies outside.
"""
function project_p_to_tr(p, M, Delta)
    nrm = sqrt(dot(p, M * p))
    return nrm <= Delta ? copy(p) : (Delta / nrm) .* p
end
