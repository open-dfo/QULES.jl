"""
    replace_farthest_old_point!(samples, x_current, target_points=0)

If more than `target_points` samples remain after appending a trial point,
remove one old sample: the first nonfinite one, otherwise the one farthest from
`x_current`. The best sample and the last (new) sample are kept.
"""
function replace_farthest_old_point!(samples::SampleSet, x_current, target_points=0)
    floor_points = max(1, target_points)
    m = length(samples.points)
    m <= floor_points && return

    best_idx = best_sample_index(samples)
    for i in 1:(m - 1)
        if i != best_idx && !is_finite_sample(samples.points[i], samples.y[i])
            deleteat!(samples.points, i)
            deleteat!(samples.y, i)
            return
        end
    end

    dists = [norm(samples.points[i] .- x_current) for i in 1:(m - 1)]
    if 1 <= best_idx <= m - 1
        dists[best_idx] = -1.0
    end
    rem_idx = argmax(dists)
    dists[rem_idx] < 0.0 && return
    deleteat!(samples.points, rem_idx)
    deleteat!(samples.y, rem_idx)
end

"""
    prune_points!(samples, x_current, max_points, min_points=0)

Remove nonfinite samples, then the samples farthest from `x_current`, until at
most `max(max_points, min_points)` remain. The best sample is kept.
"""
function prune_points!(samples::SampleSet, x_current, max_points, min_points=0)
    floor_points = max(1, min_points)
    cap = max(max_points, floor_points)
    length(samples.points) <= cap && return

    best_idx = best_sample_index(samples)
    best_idx = drop_nonfinite_samples!(samples, best_idx, cap)

    length(samples.points) <= cap && return
    dists = [norm(samples.points[k] .- x_current) for k in eachindex(samples.points)]
    dists[best_idx] = -1.0

    while length(samples.points) > cap
        rem_idx = argmax(dists)
        dists[rem_idx] < 0.0 && break
        deleteat!(samples.points, rem_idx)
        deleteat!(samples.y, rem_idx)
        deleteat!(dists, rem_idx)
    end
end

"""
    prune_far_points!(samples, x_current, Delta, rho_prune, min_points)

Remove nonfinite samples and samples farther than `rho_prune * Delta` from
`x_current`. The best sample and the `min_points` nearest samples are kept.
"""
function prune_far_points!(samples::SampleSet, x_current, Delta, rho_prune, min_points)
    m = length(samples.points)
    if m <= min_points
        return
    end

    best_idx = best_sample_index(samples)
    best_idx = drop_nonfinite_samples!(samples, best_idx, min_points)

    m = length(samples.points)
    m <= min_points && return

    dists = [norm(samples.points[k] .- x_current) for k in 1:m]
    prune_radius = rho_prune * Delta
    close_indices = Int[]
    for k in 1:m
        if dists[k] <= prune_radius
            push!(close_indices, k)
        end
    end

    if !(best_idx in close_indices)
        push!(close_indices, best_idx)
    end

    if length(close_indices) >= min_points
        keep = falses(m)
        keep[close_indices] .= true
    else
        sorted_indices = sortperm(dists)
        keep_indices = Int[]
        for idx in sorted_indices
            length(keep_indices) >= min_points && break
            push!(keep_indices, idx)
        end
        if !(best_idx in keep_indices)
            keep_indices[end] = best_idx
        end
        keep = falses(m)
        keep[keep_indices] .= true
    end

    points_new = samples.points[keep]
    y_new = samples.y[keep]

    empty!(samples.points)
    empty!(samples.y)

    append!(samples.points, points_new)
    append!(samples.y, y_new)
end

"""
    initial_coordinate_sampling!(samples, black_box, x_curr, Delta, max_evals, evals)

Sample along each coordinate direction ±Delta from `x_curr`.
Steps that leave `x_curr` unchanged due to roundoff are skipped.
Returns the updated evaluation count.
"""
function initial_coordinate_sampling!(samples::SampleSet, black_box,
                                      x_curr, Delta, max_evals, evals)
    n = length(x_curr)

    for j in 1:n
        if evals >= max_evals
            break
        end

        xp = copy(x_curr)
        xp[j] = x_curr[j] + Delta
        if xp != x_curr
            fp = black_box(xp)
            if isnan(fp)
                fp = Inf
            end

            push!(samples.points, xp)
            push!(samples.y, fp)
            evals += 1
        end

        if evals >= max_evals
            break
        end

        xm = copy(x_curr)
        xm[j] = x_curr[j] - Delta
        if xm != x_curr
            fm = black_box(xm)
            if isnan(fm)
                fm = Inf
            end

            push!(samples.points, xm)
            push!(samples.y, fm)
            evals += 1
        end
    end

    return evals
end

function is_finite_sample(p, y)
    return isfinite(y) && all(isfinite, p)
end

function find_exact_sample_index(samples::SampleSet, x)
    for i in eachindex(samples.points)
        if samples.points[i] == x
            return i
        end
    end
    return 0
end

"""
    best_sample_index(samples)

Index of the lowest finite sample, or of `argmin(samples.y)` if no sample is
finite; `0` for an empty set.
"""
function best_sample_index(samples::SampleSet)
    isempty(samples.points) && return 0
    best_idx = 0
    best_y = Inf
    for i in eachindex(samples.points)
        if is_finite_sample(samples.points[i], samples.y[i]) && samples.y[i] < best_y
            best_y = samples.y[i]
            best_idx = i
        end
    end
    return best_idx == 0 ? argmin(samples.y) : best_idx
end

"""
    drop_nonfinite_samples!(samples, best_idx, min_points)

Delete nonfinite samples other than `best_idx`, in index order, while more
than `min_points` samples remain. Return the updated index of the best sample.
"""
function drop_nonfinite_samples!(samples::SampleSet, best_idx, min_points)
    i = 1
    while i <= length(samples.points) && length(samples.points) > min_points
        if i != best_idx && !is_finite_sample(samples.points[i], samples.y[i])
            deleteat!(samples.points, i)
            deleteat!(samples.y, i)
            if best_idx > i
                best_idx -= 1
            end
        else
            i += 1
        end
    end
    return best_idx
end