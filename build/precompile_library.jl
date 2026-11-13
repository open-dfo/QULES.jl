# Executed by PackageCompiler's precompile_execution_file, not by using QULES.
module NativePrecompile

using QULES
using QULES: qules_set_log_mode, qules_log_read, NativeLog, MOI,
             LOG_MODE_CALLBACK, LOG_MODE_BUFFER, LOG_MODE_STDOUT

quadratic(x) = (x[1] - 1.0)^2 + 10.0 * (x[2] + 2.0)^2
rosenbrock(x) =
    sum(100.0 * (x[i + 1] - x[i]^2)^2 + (1.0 - x[i])^2 for i in 1:(length(x) - 1))

function c_objective(n::Csize_t, x::Ptr{Cdouble}, f::Ptr{Cvoid})::Cdouble
    objective = unsafe_pointer_to_objref(f)::Base.RefValue{Function}
    return Float64(objective[](unsafe_wrap(Array, x, Int(n))))
end

c_log(::Cstring, ::Ptr{Cvoid})::Cvoid = nothing

# The 3-D case exercises geometry repair as well as the basic solver path.
const CASES = (
    (quadratic, [3.0, 1.0], 8),
    (rosenbrock, [-1.2, 1.0, 0.5], 80),
)

function optimize_c(callback, objective, x_start, max_evals, verbose, rotation)
    n = length(x_start)
    objective_box = Ref{Function}(objective)
    x_best = zeros(n)
    f_best = Ref{Cdouble}(0.0)
    evals = Ref{Csize_t}(0)
    Delta = Ref{Cdouble}(0.0)
    GC.@preserve objective_box x_start x_best f_best evals Delta begin
        status = qules_optimize_c(
            callback, Csize_t(n), pointer(x_start), Csize_t(max_evals),
            1.0, 1e-8, 100.0, Cint(verbose), Cint(rotation), pointer(x_best),
            Base.unsafe_convert(Ptr{Cdouble}, f_best),
            Base.unsafe_convert(Ptr{Csize_t}, evals),
            Base.unsafe_convert(Ptr{Cdouble}, Delta), pointer_from_objref(objective_box),
        )
    end
    status == 0 || error("QULES native precompile workload failed (status=$status)")
    return nothing
end

function session(objective, x_start, max_evals, verbose, rotation)
    n = length(x_start)
    x = zeros(n)
    GC.@preserve x_start begin
        id = qules_session_create(Csize_t(n), pointer(x_start), Csize_t(max_evals),
                                  1.0, 1e-8, 100.0, Cint(verbose), Cint(rotation))
    end
    id > 0 || error("QULES session precompile workload failed (id=$id)")
    GC.@preserve x begin
        while qules_session_ask(id, pointer(x)) == 1
            qules_session_tell(id, objective(x))
        end
    end
    qules_session_is_finished(id) == 1 || error("QULES session did not finish")
    x_best = zeros(n)
    f_best = Ref{Cdouble}(0.0)
    evals = Ref{Csize_t}(0)
    Delta = Ref{Cdouble}(0.0)
    GC.@preserve x_best f_best evals Delta begin
        status = qules_session_get_best(
            id, pointer(x_best), Base.unsafe_convert(Ptr{Cdouble}, f_best),
            Base.unsafe_convert(Ptr{Csize_t}, evals),
            Base.unsafe_convert(Ptr{Cdouble}, Delta),
        )
    end
    status == 0 || error("QULES session result unavailable (status=$status)")
    qules_session_free(id)
    return nothing
end

# Log paths the cases above need not reach: inner-solver failures and every
# termination message. Without IR the bundle cannot compile them on demand.
# The solver passes `config.log_io::IO`, so these calls go through the same
# runtime dispatch instead of being inlined here.
function rare_log_paths()
    config = QULESConfig(log_io=NativeLog())
    for status in (MOI.ITERATION_LIMIT, MOI.TIME_LIMIT, MOI.LOCALLY_INFEASIBLE,
                   MOI.INFEASIBLE, MOI.NUMERICAL_ERROR, MOI.INVALID_MODEL, MOI.OTHER_ERROR)
        QULES.print_inner_failure(status, 1; io=config.log_io)
    end
    samples = SampleSet([[0.0]], [0.0])
    reasons = ["max_evals", "delta_min", "flat_line", "geometry_stall",
               "nonfinite_geometry", "stopped"]
    QULES.print_termination(samples, 1, 1.0, config, reasons;
                            function_value_range=0.0, io=config.log_io)
    flush(config.log_io)
    return nothing
end

precompile(Core.kwcall, (NamedTuple{(:io,), Tuple{NativeLog}}, typeof(QULES.print_inner_failure),
                         MOI.TerminationStatusCode, Int))

function run_workload()
    callback = @cfunction(c_objective, Cdouble, (Csize_t, Ptr{Cdouble}, Ptr{Cvoid}))
    log_callback = @cfunction(c_log, Cvoid, (Cstring, Ptr{Cvoid}))

    for (objective, x_start, max_evals) in CASES, rotation in (true, false)
        optimize_qules(objective, x_start; max_evals=max_evals, rotation=rotation, verbose=false)
        optimize_qules(objective, x_start; max_evals=max_evals, rotation=rotation,
                       verbose=true, log_io=IOBuffer())

        qules_set_log_mode(LOG_MODE_CALLBACK, log_callback, C_NULL)
        rare_log_paths()
        optimize_c(callback, objective, x_start, max_evals, false, rotation)
        optimize_c(callback, objective, x_start, max_evals, true, rotation)
        session(objective, x_start, max_evals, true, rotation)

        qules_set_log_mode(LOG_MODE_BUFFER, C_NULL, C_NULL)
        session(objective, x_start, max_evals, true, rotation)
        pending = Vector{UInt8}(undef, 256)
        GC.@preserve pending begin
            qules_log_read(Ptr{UInt8}(C_NULL), Csize_t(0))
            while qules_log_read(pointer(pending), Csize_t(length(pending))) > 0
            end
        end
    end

    # Reset the callback pointers and exercise native stdout with a short run.
    qules_set_log_mode(LOG_MODE_STDOUT, C_NULL, C_NULL)
    optimize_c(callback, quadratic, [3.0, 1.0], 3, true, true)
    return nothing
end

end # module NativePrecompile

NativePrecompile.run_workload()
