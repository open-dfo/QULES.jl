# C-ABI and multi-language interface for QULES.jl.

"""
    QULESSession

Ask/tell driver for hosts that cannot pass a callback. `optimize_qules` runs
unchanged on a Julia task; each objective evaluation it requests is handed to
the host through `ask`, and the host's value is returned through `tell`. The
session therefore follows exactly the same iterates as the one-shot optimizer.
"""
mutable struct QULESSession
    n::Int
    config::QULESConfig
    ask::Channel{Vector{Float64}}
    tell::Channel{Float64}
    task::Task
    pending::Union{Nothing,Vector{Float64}}  # point handed out, awaiting its value
    evals::Int
    best_x::Vector{Float64}
    best_f::Float64
    result::Any                               # optimize_qules result once finished
    finished::Bool
end

const SESSIONS = Dict{Int64, QULESSession}()
const SESSIONS_LOCK = ReentrantLock()
const global_session_counter = Ref{Int64}(0)

"""
    create_qules_session(n, x_start, config) -> Int64

Create an ask/tell session and return its id. `n` must be positive and match
the length of the starting point.
"""
function create_qules_session(
    n::Int,
    x_start::Vector{Float64},
    config::QULESConfig
)::Int64
    n > 0 || throw(ArgumentError("n must be positive"))
    length(x_start) == n || throw(DimensionMismatch(
        "x_start has length $(length(x_start)); expected $n"))

    ask = Channel{Vector{Float64}}(0)
    tell = Channel{Float64}(0)
    black_box = function (x::Vector{Float64})
        put!(ask, copy(x))
        return take!(tell)
    end
    task = Task() do
        try
            return optimize_qules(black_box, copy(x_start), config)
        finally
            close(ask)
        end
    end
    session = QULESSession(n, config, ask, tell, task, nothing, 0,
                           copy(x_start), Inf, nothing, false)
    schedule(task)

    lock(SESSIONS_LOCK) do
        global_session_counter[] += 1
        id = global_session_counter[]
        SESSIONS[id] = session
        return id
    end
end

function finish_session!(session::QULESSession)
    session.finished = true
    close(session.tell)
    if istaskdone(session.task) && !istaskfailed(session.task)
        session.result = fetch(session.task)
    end
    return nothing
end

"""
    free_qules_session(session_id) -> Bool

Remove a session. Returns `false` if the id is unknown.
"""
function free_qules_session(session_id::Int64)::Bool
    session = lock(SESSIONS_LOCK) do
        pop!(SESSIONS, session_id, nothing)
    end
    session === nothing && return false
    session.finished || finish_session!(session)
    return true
end

"""
    session_step_ask!(session, x_out) -> Bool

Write the next point to evaluate into `x_out`. Returns `false` once the session
has finished. Asking again before telling returns the same point.
"""
function session_step_ask!(session::QULESSession, x_out::Vector{Float64})::Bool
    session.finished && return false
    if session.pending === nothing
        x = try
            take!(session.ask)
        catch err
            err isa InvalidStateException || rethrow()
            nothing
        end
        if x === nothing
            finish_session!(session)
            istaskfailed(session.task) && throw(TaskFailedException(session.task))
            return false
        end
        session.pending = x
    end
    x_out .= session.pending
    return true
end

"""
    session_step_tell!(session, f_val) -> Bool

Report the function value at the last asked point and advance the optimizer to
its next request. Returns `false` if no point is awaiting a value.
"""
function session_step_tell!(session::QULESSession, f_val::Float64)::Bool
    session.finished && return false
    x = session.pending
    x === nothing && return false
    session.pending = nothing
    session.evals += 1
    if f_val < session.best_f
        session.best_f = f_val
        session.best_x = x
    end
    put!(session.tell, f_val)
    return true
end

# Verbose output for native hosts. Lines are assembled in NativeLog and handed
# to the host by the selected mode; the Julia `stdout` object is never used from
# the C entry points because its runtime type is not part of the compiled image.
const LOG_MODE_STDOUT = Cint(0)
const LOG_MODE_CALLBACK = Cint(1)
const LOG_MODE_BUFFER = Cint(2)

const LOG_MODE = Ref{Cint}(LOG_MODE_STDOUT)
const LOG_CALLBACK = Ref{Ptr{Cvoid}}(C_NULL)
const LOG_USER_DATA = Ref{Ptr{Cvoid}}(C_NULL)
const LOG_BUFFER = IOBuffer()
const LOG_LOCK = ReentrantLock()

struct NativeLog <: IO
    pending::IOBuffer
end
NativeLog() = NativeLog(IOBuffer())

function Base.unsafe_write(io::NativeLog, p::Ptr{UInt8}, n::UInt)
    written = unsafe_write(io.pending, p, n)
    deliver_log_lines!(io, false)
    return written
end

function Base.write(io::NativeLog, b::UInt8)
    write(io.pending, b)
    deliver_log_lines!(io, false)
    return 1
end

Base.flush(io::NativeLog) = deliver_log_lines!(io, true)

function deliver_log_lines!(io::NativeLog, everything::Bool)
    data = take!(io.pending)
    last_newline = findlast(==(UInt8('\n')), data)
    cut = everything ? length(data) : (last_newline === nothing ? 0 : last_newline)
    cut > 0 && deliver_log(String(data[1:cut]))
    cut < length(data) && write(io.pending, @view data[(cut + 1):end])
    return nothing
end

function deliver_log(text::String)
    mode = LOG_MODE[]
    if mode == LOG_MODE_CALLBACK
        ccall(LOG_CALLBACK[], Cvoid, (Cstring, Ptr{Cvoid}), text, LOG_USER_DATA[])
    elseif mode == LOG_MODE_BUFFER
        lock(LOG_LOCK) do
            write(LOG_BUFFER, text)
        end
    else
        stream = unsafe_load(cglobal(:jl_uv_stdout, Ptr{Cvoid}))
        GC.@preserve text ccall(:jl_uv_puts, Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
                                stream, pointer(text), sizeof(text))
    end
    return nothing
end

function native_config(max_evals, delta0, delta_min, delta_max, verbose, rotation)
    return QULESConfig(
        max_evals = Int(max_evals),
        Delta0 = Float64(delta0),
        Delta_min = Float64(delta_min),
        Delta_max = Float64(delta_max),
        verbose = (verbose != 0),
        log_io = NativeLog(),
        rotation = (rotation != 0),
    )
end

# C-callable exports.

Base.@ccallable function qules_set_log_mode(
    mode::Cint,
    callback::Ptr{Cvoid},
    user_data::Ptr{Cvoid}
)::Cint
    LOG_MODE_STDOUT <= mode <= LOG_MODE_BUFFER || return Cint(-1)
    mode == LOG_MODE_CALLBACK && callback == C_NULL && return Cint(-1)
    LOG_MODE[] = mode
    LOG_CALLBACK[] = callback
    LOG_USER_DATA[] = user_data
    return Cint(0)
end

Base.@ccallable function qules_log_read(
    buffer::Ptr{UInt8},
    capacity::Csize_t
)::Csize_t
    lock(LOG_LOCK) do
        pending = take!(LOG_BUFFER)
        if buffer == C_NULL || capacity == 0
            write(LOG_BUFFER, pending)
            return Csize_t(length(pending))
        end
        count = min(length(pending), Int(capacity) - 1)
        count > 0 && unsafe_copyto!(buffer, pointer(pending), count)
        unsafe_store!(buffer, 0x00, count + 1)
        count < length(pending) && write(LOG_BUFFER, @view pending[(count + 1):end])
        return Csize_t(count)
    end
end

# Fixed at compile time from Project.toml; the native bundle has no Project.toml.
const QULES_VERSION = pkgversion(@__MODULE__)
include_dependency(joinpath(pkgdir(@__MODULE__), "Project.toml"))

Base.@ccallable function qules_version_major()::Cint
    return Cint(QULES_VERSION.major)
end

Base.@ccallable function qules_version_minor()::Cint
    return Cint(QULES_VERSION.minor)
end

Base.@ccallable function qules_version_patch()::Cint
    return Cint(QULES_VERSION.patch)
end

Base.@ccallable function qules_session_create(
    n_dim::Csize_t,
    x_start_ptr::Ptr{Cdouble},
    max_evals::Csize_t,
    delta0::Cdouble,
    delta_min::Cdouble,
    delta_max::Cdouble,
    verbose::Cint,
    rotation::Cint
)::Int64
    try
        n = Int(n_dim)
        n > 0 && x_start_ptr != C_NULL || return Int64(-1)

        x_start = copy(unsafe_wrap(Array, x_start_ptr, n))

        config = native_config(max_evals, delta0, delta_min, delta_max, verbose, rotation)

        return create_qules_session(n, x_start, config)
    catch
        return Int64(-2)
    end
end

Base.@ccallable function qules_session_ask(
    session_id::Int64,
    x_out_ptr::Ptr{Cdouble}
)::Cint
    session = lock(SESSIONS_LOCK) do
        get(SESSIONS, session_id, nothing)
    end
    if session === nothing || x_out_ptr == C_NULL
        return Cint(0)
    end

    try
        x_buf = zeros(session.n)
        active = session_step_ask!(session, x_buf)
        if active
            unsafe_copyto!(x_out_ptr, pointer(x_buf), session.n)
            return Cint(1)
        else
            return Cint(0)
        end
    catch
        return Cint(-2)
    end
end

Base.@ccallable function qules_session_tell(
    session_id::Int64,
    f_val::Cdouble
)::Cint
    session = lock(SESSIONS_LOCK) do
        get(SESSIONS, session_id, nothing)
    end
    if session === nothing
        return Cint(-1)
    end

    try
        ok = session_step_tell!(session, Float64(f_val))
        return ok ? Cint(0) : Cint(1)
    catch
        return Cint(-2)
    end
end

Base.@ccallable function qules_session_is_finished(
    session_id::Int64
)::Cint
    session = lock(SESSIONS_LOCK) do
        get(SESSIONS, session_id, nothing)
    end
    if session === nothing
        return Cint(1)
    end
    return session.finished ? Cint(1) : Cint(0)
end

Base.@ccallable function qules_session_get_best(
    session_id::Int64,
    x_best_ptr::Ptr{Cdouble},
    f_best_ptr::Ptr{Cdouble},
    evals_ptr::Ptr{Csize_t},
    delta_ptr::Ptr{Cdouble}
)::Cint
    session = lock(SESSIONS_LOCK) do
        get(SESSIONS, session_id, nothing)
    end
    if session === nothing || session.evals == 0
        return Cint(-1)
    end

    try
        result = session.result
        best_x = result === nothing ? session.best_x : result.x_best
        best_f = result === nothing ? session.best_f : result.f_best
        Delta = result === nothing ? NaN : result.Delta   # final radius known at the end

        if x_best_ptr != C_NULL
            unsafe_copyto!(x_best_ptr, pointer(best_x), session.n)
        end
        if f_best_ptr != C_NULL
            unsafe_store!(f_best_ptr, best_f)
        end
        if evals_ptr != C_NULL
            unsafe_store!(evals_ptr, Csize_t(session.evals))
        end
        if delta_ptr != C_NULL
            unsafe_store!(delta_ptr, Delta)
        end
        return Cint(0)
    catch
        return Cint(-2)
    end
end

Base.@ccallable function qules_session_free(
    session_id::Int64
)::Cint
    ok = free_qules_session(session_id)
    return ok ? Cint(0) : Cint(-1)
end

Base.@ccallable function qules_optimize_c(
    f_callback::Ptr{Cvoid},
    n_dim::Csize_t,
    x_start_ptr::Ptr{Cdouble},
    max_evals::Csize_t,
    delta0::Cdouble,
    delta_min::Cdouble,
    delta_max::Cdouble,
    verbose::Cint,
    rotation::Cint,
    x_best_out_ptr::Ptr{Cdouble},
    f_best_out_ptr::Ptr{Cdouble},
    evals_out_ptr::Ptr{Csize_t},
    delta_out_ptr::Ptr{Cdouble},
    user_data::Ptr{Cvoid}
)::Cint
    if f_callback == C_NULL || x_start_ptr == C_NULL || n_dim <= 0
        return Cint(-1)
    end

    try
        n = Int(n_dim)
        x_start = copy(unsafe_wrap(Array, x_start_ptr, n))

        config = native_config(max_evals, delta0, delta_min, delta_max, verbose, rotation)

        obj_wrapper = (x_vec::Vector{Float64}) -> begin
            return ccall(f_callback, Cdouble, (Csize_t, Ptr{Cdouble}, Ptr{Cvoid}), Csize_t(n), pointer(x_vec), user_data)
        end

        res = optimize_qules(obj_wrapper, x_start, config)

        if x_best_out_ptr != C_NULL
            unsafe_copyto!(x_best_out_ptr, pointer(res.x_best), n)
        end
        if f_best_out_ptr != C_NULL
            unsafe_store!(f_best_out_ptr, res.f_best)
        end
        if evals_out_ptr != C_NULL
            unsafe_store!(evals_out_ptr, Csize_t(res.evals))
        end
        if delta_out_ptr != C_NULL
            unsafe_store!(delta_out_ptr, res.Delta)
        end

        return Cint(0)
    catch
        return Cint(-2)
    end
end
