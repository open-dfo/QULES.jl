"""
    solve_inner_problem(samples, x_current, f_curr, Delta, config; V_ext=nothing)

Minimize the diagonal-envelope gap over the step and curvatures.
The envelope axes are the coordinate axes, or the columns of the frame `V_ext`.
The variables are not rescaled; the trust region is `‖p‖ ≤ Delta`.

Return `valid` and the solver `status`; valid solutions also include the trial
point `xplus` and predicted decrease `pred_dec`.
"""
function solve_inner_problem(samples::SampleSet, x_current, f_curr, Delta,
    config::QULESConfig; V_ext=nothing)

    n = length(x_current)

    # Consider only samples with finite objective and coordinates.
    finite_mask = [isfinite(y) && all(isfinite, p) for (p, y) in zip(samples.points, samples.y)]
    valid_points = samples.points[finite_mask]
    valid_y = samples.y[finite_mask]

    if length(valid_points) < n + 1
        return (valid=false, status=MOI.INVALID_MODEL)
    end

    scaling = scale_inner_samples(valid_points, valid_y, x_current, f_curr)

    V = V_ext === nothing ? Matrix{Float64}(I, n, n) : Matrix{Float64}(V_ext)

    S_rot = [V' * si for si in scaling.S]

    # Normalize the trust-region radius to one.
    S_hat_rot = [si ./ Delta for si in S_rot]
    δ_hat = scaling.δ ./ Delta

    # Trust region ‖p‖ ≤ Delta in frame coordinates.
    M = V' * V

    p0_rot, alpha0_rot, beta0_rot = build_start_p_alpha_beta(S_hat_rot, δ_hat, M, 1.0)

    envelope = build_envelope_model(S_hat_rot, δ_hat, M, config)
    model = envelope.model
    p_hat, alpha_hat, beta_hat = envelope.p_hat, envelope.alpha_hat, envelope.beta_hat

    set_start_value.(p_hat, p0_rot)
    set_start_value.(alpha_hat, alpha0_rot)
    set_start_value.(beta_hat, beta0_rot)

    optimize!(model)

    return recover_inner_result(model, p_hat, beta_hat, x_current, Delta, V, scaling.y_scale)
end

"""
    build_envelope_model(S_hat_rot, δ_hat, M, config)

Build the envelope constraints and gap objective in normalized frame coordinates.
`M` expresses the trust region in those coordinates.
Return the model and its step and curvature variables, without solving it.
"""
function build_envelope_model(S_hat_rot, δ_hat, M, config::QULESConfig)
    n = size(M, 1)
    model = create_solver_model(config)

    @variable(model, p_hat[1:n])
    @variable(model, alpha_hat[1:n] >= config.inner_tol)
    @variable(model, beta_hat[1:n] >= config.inner_tol)

    @constraint(model, [j = 1:n], alpha_hat[j] <= beta_hat[j])

    @NLconstraint(model,
        sum(p_hat[r] * M[r, c] * p_hat[c] for r in 1:n, c in 1:n) <= 1.0
    )

    for i in eachindex(S_hat_rot)
        si_hat = S_hat_rot[i]

        @NLconstraint(model,
            δ_hat[i] <=
            sum(beta_hat[j] * (p_hat[j] * si_hat[j] + 0.5 * si_hat[j]^2) for j in 1:n)
        )

        @NLconstraint(model,
            δ_hat[i] >=
            0.5 * sum(alpha_hat[j] * (si_hat[j] + p_hat[j])^2 for j in 1:n)
            -
            0.5 * sum(beta_hat[j] * p_hat[j]^2 for j in 1:n)
        )
    end

    @objective(model, Min, sum(beta_hat[j] - alpha_hat[j] for j in 1:n))
    return (model=model, p_hat=p_hat, alpha_hat=alpha_hat, beta_hat=beta_hat)
end

"""
    recover_inner_result(model, p_hat, beta_hat, x_current, Delta, V, y_scale)

Check solver termination and recover the trial point and predicted decrease.
The columns of `V` are the envelope axes.
"""
function recover_inner_result(model, p_hat, beta_hat, x_current, Delta, V, y_scale)
    st = termination_status(model)

    good_status =
        st == MOI.OPTIMAL ||
        st == MOI.LOCALLY_SOLVED ||
        st == MOI.ALMOST_LOCALLY_SOLVED

    if !good_status
        return (valid=false, status=st)
    end

    beta = value.(beta_hat) ./ Delta
    p_rot = Delta .* value.(p_hat)
    pred_dec = 0.5 * sum(beta[j] * p_rot[j]^2 for j in eachindex(beta))
    return (
        valid=true,
        status=st,
        xplus=x_current .- V * p_rot,
        pred_dec=pred_dec * y_scale
    )
end
