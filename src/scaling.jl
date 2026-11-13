"""
    scale_inner_samples(points, y, x_current, f_curr)

Form displacements from the center and function-value differences divided by
the largest function-value magnitude (at least 1). The variables are not rescaled.
Return the displacements `S`, the differences `δ`, and `y_scale`.
"""
function scale_inner_samples(points, y, x_current, f_curr)
    y_scale = max(1.0, maximum(abs.(y)), abs(f_curr))

    y_s = y ./ y_scale
    f_curr_s = f_curr / y_scale

    S = [pt .- x_current for pt in points]
    δ = y_s .- f_curr_s

    return (S=S, δ=δ, y_scale=y_scale)
end
