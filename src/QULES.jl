module QULES

using JuMP
using Ipopt
using LinearAlgebra
using Printf
using PrecompileTools: @setup_workload, @compile_workload

const MOI = JuMP.MOI

include("types.jl")
include("scaling.jl")
include("samples.jl")
include("geometry.jl")
include("warm_starting.jl")
include("solver.jl")
include("inner_problem.jl")
include("orientation.jl")
include("trust_region.jl")
include("console.jl")
include("optimizer.jl")
include("c_api.jl")
include("precompile.jl")

export QULESConfig, SampleSet
export optimize_qules
export solve_inner_problem
export orientation_update, build_givens, jacobi_pair_update, jacobi_orientation_sweep
export sample_geometry_ok, least_represented_direction
export QULESSession, create_qules_session, free_qules_session, session_step_ask!, session_step_tell!
export qules_session_create, qules_session_ask, qules_session_tell, qules_session_get_best, qules_session_is_finished, qules_session_free, qules_optimize_c

end
