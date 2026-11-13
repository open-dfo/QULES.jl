"""
    QULESConfig

QULES optimizer settings; each field can be passed as a keyword to `optimize_qules`.
"""
Base.@kwdef struct QULESConfig
    max_evals::Int         = 300
    Delta0::Float64        = 1.0
    Delta_min::Float64     = 1e-8
    Delta_max::Float64     = 100.0
    eta_accept::Float64    = 1e-6
    kappa_delta::Float64   = 0.1
    gamma_inc::Float64     = 1.25
    theta_fail::Float64    = 0.75
    theta_small::Float64   = 0.8
    rho_prune::Float64     = 2.5
    sample_capacity_factor::Int = 3
    sigma_s::Float64       = 0.01
    inner_tol::Float64     = 1e-12
    inner_optimizer::Any   = nothing
    verbose::Bool          = true
    log_io::IO             = stdout
    rotation::Bool         = true
end

"""
    SampleSet

Sample points and their function values.
"""
mutable struct SampleSet
    points::Vector{Vector{Float64}}
    y::Vector{Float64}
end

SampleSet() = SampleSet(Vector{Vector{Float64}}(), Float64[])

