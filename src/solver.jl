"""Create a JuMP model with the supplied optimizer or the default Ipopt settings."""
function create_solver_model(config::QULESConfig)
    optimizer = config.inner_optimizer
    if optimizer === nothing
        optimizer = optimizer_with_attributes(
            Ipopt.Optimizer,
            "print_level" => 0,
            "sb" => "yes",
            "max_iter" => 3000,
            "expect_infeasible_problem" => "no",
            "mu_strategy" => "adaptive",
            "mu_oracle" => "quality-function",
            "tol" => 1e-12,
            "bound_relax_factor" => 0.0,
        )
    end
    return Model(optimizer)
end
