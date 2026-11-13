"""
    update_trust_region(Delta, step_norm, actual_reduction, pred_dec, config)

Accept when `actual_reduction <= -eta_accept * pred_dec`, where actual
reduction is `f_next - f_curr`. Update the radius using relative step length.
Return `(new_Delta, status, accepted)`, with status describing the radius update.
"""
function update_trust_region(Delta, step_norm, actual_reduction, pred_dec,
                             config::QULESConfig)

    required_reduction = -config.eta_accept * pred_dec

    accepted = actual_reduction <= required_reduction

    if accepted
        if step_norm >= config.kappa_delta * Delta
            new_Delta = min(config.gamma_inc * Delta, config.Delta_max)
            status = "success_expand"
        else
            new_Delta = config.theta_small * Delta
            status = "success_shrink"
        end
    else
        new_Delta = config.theta_fail * Delta
        status = "fail"
    end

    return new_Delta, status, accepted
end
