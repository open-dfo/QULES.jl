/// @file qules.hpp
/// Header-only C++17 binding for the QULES Windows x64 bundle. See README.md.
///
/// bin/qules.dll is loaded with LoadLibrary when the Runtime is constructed;
/// the prototypes in qules::detail::Api mirror the bundle's include/qules.h.
///
/// Not thread-safe: Julia runs on the thread that built the Runtime and the
/// verbose log route is process-wide.
#pragma once

#ifndef _WIN32
#error "qules.hpp targets the Windows x64 bundle"
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <exception>
#include <filesystem>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace qules {

/// Thrown when a QULES C entry point returns a non-zero status.
class Error : public std::runtime_error {
public:
    /// Raw status code returned by the C entry point (see the bundle's qules.h).
    int status;
    Error(int status_, const std::string& what) : std::runtime_error(what), status(status_) {}
};

/// Optimizer settings shared by optimize() and Session.
struct Options {
    /// Maximum number of objective evaluations.
    std::size_t max_evals = 300;
    /// Initial trust-region radius.
    double delta0 = 1.0;
    /// Smallest trust-region radius; the run stops once it is reached.
    double delta_min = 1e-8;
    /// Largest trust-region radius.
    double delta_max = 100.0;
    /// Print the iteration table (to stdout, or to @ref log when set).
    bool verbose = false;
    /// Learn the envelope orientation; false keeps coordinate axes.
    bool rotation = true;
    /// With @ref verbose, receives each log line (without its newline). When
    /// unset, verbose output goes to the process's standard output.
    std::function<void(std::string_view)> log;
};

/// Outcome of an optimizer run.
struct Result {
    /// Best point found; has the same size as the start point.
    std::vector<double> x_best;
    /// Objective value at @ref x_best.
    double f_best = 0.0;
    /// Number of objective evaluations performed.
    std::size_t evals = 0;
    /// Final trust-region radius (NaN from Session::best() before the session finished).
    double delta = 0.0;
};

/// Objective function: takes the current point and returns its value.
/// Exceptions thrown here are propagated out of optimize().
using Objective = std::function<double(const std::vector<double>&)>;

namespace detail {

using LogCallback = void (*)(const char*, void*);

// Entry points resolved from qules.dll; prototypes mirror the bundle's qules.h.
struct Api {
    void (*init_julia)(int, char**) = nullptr;
    void (*shutdown_julia)(int) = nullptr;
    int (*set_log_mode)(int, LogCallback, void*) = nullptr;
    int (*optimize_c)(void*, std::size_t, const double*, std::size_t, double, double, double,
                      int, int, double*, double*, std::size_t*, double*, void*) = nullptr;
    std::int64_t (*session_create)(std::size_t, const double*, std::size_t, double, double,
                                   double, int, int) = nullptr;
    int (*session_ask)(std::int64_t, double*) = nullptr;
    int (*session_tell)(std::int64_t, double) = nullptr;
    int (*session_is_finished)(std::int64_t) = nullptr;
    int (*session_get_best)(std::int64_t, double*, double*, std::size_t*, double*) = nullptr;
    int (*session_free)(std::int64_t) = nullptr;
};

inline Api g_api;
inline bool g_started = false;  // set once by Runtime; Julia is never re-initialized

inline const Api& api() {
    if (!g_started) {
        throw std::logic_error("qules: construct a qules::Runtime before using the optimizer");
    }
    return g_api;
}

template <class F>
void load_symbol(HMODULE dll, F& slot, const char* name) {
    slot = reinterpret_cast<F>(reinterpret_cast<void*>(GetProcAddress(dll, name)));
    if (slot == nullptr) {
        throw std::runtime_error(std::string("qules: qules.dll does not export ") + name);
    }
}

inline void check(int status, const char* call) {
    if (status != 0) {
        throw Error(status, std::string("qules: ") + call + " returned " + std::to_string(status));
    }
}

inline double nan() { return std::numeric_limits<double>::quiet_NaN(); }

// Converts a narrow string to wide. Valid UTF-8 is decoded as UTF-8; anything
// else is decoded in the system ANSI code page, which is what narrow argv and
// getenv deliver on Windows unless the executable opts into UTF-8.
inline std::wstring narrow_to_wide(std::string_view text) {
    if (text.empty()) return std::wstring();
    if (text.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        throw std::invalid_argument("qules: path too long");
    }
    const int length = static_cast<int>(text.size());
    UINT code_page = CP_UTF8;
    DWORD flags = MB_ERR_INVALID_CHARS;
    int needed = MultiByteToWideChar(code_page, flags, text.data(), length, nullptr, 0);
    if (needed <= 0) {
        code_page = CP_ACP;
        flags = 0;
        needed = MultiByteToWideChar(code_page, flags, text.data(), length, nullptr, 0);
    }
    if (needed <= 0) {
        throw std::invalid_argument("qules: bundle directory string cannot be decoded, error " +
                                    std::to_string(GetLastError()));
    }
    std::wstring wide(static_cast<std::size_t>(needed), L'\0');
    MultiByteToWideChar(code_page, flags, text.data(), length, wide.data(), needed);
    return wide;
}

// Routes verbose output to Options::log for the lifetime of the object.
// The C side delivers chunks ending in '\n' (possibly several lines at once)
// and a final flush may deliver a fragment without one; lines are split here.
class LogRoute {
public:
    explicit LogRoute(const Options& options) {
        if (!options.verbose || !options.log) return;
        sink_ = &options.log;
        check(api().set_log_mode(1, &LogRoute::receive, this), "qules_set_log_mode");
        active_ = true;
    }
    ~LogRoute() {
        if (active_) g_api.set_log_mode(0, nullptr, nullptr);
    }
    LogRoute(const LogRoute&) = delete;
    LogRoute& operator=(const LogRoute&) = delete;

    // Delivers any trailing fragment and re-raises an exception thrown by the sink.
    void finish() {
        if (!active_) return;
        if (!error_ && !pending_.empty()) {
            try {
                (*sink_)(pending_);
            } catch (...) {
                error_ = std::current_exception();
            }
            pending_.clear();
        }
        if (error_) std::rethrow_exception(error_);
    }

private:
    static void receive(const char* text, void* user_data) noexcept {
        auto* self = static_cast<LogRoute*>(user_data);
        if (self->error_ || text == nullptr) return;
        try {
            self->pending_ += text;
            std::size_t start = 0;
            for (;;) {
                std::size_t newline = self->pending_.find('\n', start);
                if (newline == std::string::npos) break;
                std::size_t end = newline;
                if (end > start && self->pending_[end - 1] == '\r') --end;
                (*self->sink_)(std::string_view(self->pending_).substr(start, end - start));
                start = newline + 1;
            }
            self->pending_.erase(0, start);
        } catch (...) {
            self->error_ = std::current_exception();
        }
    }

    const std::function<void(std::string_view)>* sink_ = nullptr;
    std::string pending_;
    std::exception_ptr error_;
    bool active_ = false;
};

// Objective trampoline state. After f throws, the exception is kept, NaN is
// returned, and f is not called again for the rest of that optimizer run.
struct Call {
    const Objective* f;
    std::vector<double> x;
    std::exception_ptr error;

    static double trampoline(std::size_t n, const double* x, void* user_data) noexcept {
        auto* call = static_cast<Call*>(user_data);
        if (call->error) return nan();
        try {
            call->x.assign(x, x + n);
            return (*call->f)(call->x);
        } catch (...) {
            call->error = std::current_exception();
            return nan();
        }
    }
};

}  // namespace detail

/// Loads `bundle_dir/bin/qules.dll` and initializes the embedded Julia runtime.
///
/// Lifetime rules:
/// - Construct exactly one Runtime per process, before any optimize() or
///   Session call, and keep it alive until the last call has returned.
///   A second construction throws `std::logic_error`, even after the first
///   Runtime was destroyed: Julia cannot be re-initialized in one process.
/// - The destructor shuts Julia down; destroy it from the thread that built it,
///   typically by letting it go out of scope at the end of `main`.
/// - Construction throws `std::runtime_error` when the directory is not a
///   bundle, the DLL cannot be loaded, or an export is missing.
class Runtime {
public:
    /// @param bundle_dir Directory containing `bin/qules.dll` (any encoding
    ///        std::filesystem::path accepts; use the wide form for non-ASCII paths
    ///        when the caller has wide command-line arguments).
    explicit Runtime(const std::filesystem::path& bundle_dir) {
        if (detail::g_started) {
            throw std::logic_error("qules: Julia was already initialized in this process");
        }
        std::filesystem::path bin = bundle_dir / "bin";
        std::filesystem::path dll = bin / "qules.dll";
        if (!std::filesystem::is_regular_file(dll)) {
            throw std::runtime_error("qules: not a QULES bundle (missing bin/qules.dll): " +
                                     bundle_dir.string());
        }
        // Julia loads the remaining runtime DLLs by name, so bin must be on the
        // default search path, not just the directory of qules.dll.
        if (!SetDllDirectoryW(bin.c_str())) {
            throw std::runtime_error("qules: SetDllDirectoryW failed, error " +
                                     std::to_string(GetLastError()));
        }
        HMODULE handle = LoadLibraryW(dll.c_str());
        if (handle == nullptr) {
            throw std::runtime_error("qules: LoadLibraryW failed for " + dll.string() +
                                     ", error " + std::to_string(GetLastError()));
        }
        detail::Api api;
        detail::load_symbol(handle, api.init_julia, "init_julia");
        detail::load_symbol(handle, api.shutdown_julia, "shutdown_julia");
        detail::load_symbol(handle, api.set_log_mode, "qules_set_log_mode");
        detail::load_symbol(handle, api.optimize_c, "qules_optimize_c");
        detail::load_symbol(handle, api.session_create, "qules_session_create");
        detail::load_symbol(handle, api.session_ask, "qules_session_ask");
        detail::load_symbol(handle, api.session_tell, "qules_session_tell");
        detail::load_symbol(handle, api.session_is_finished, "qules_session_is_finished");
        detail::load_symbol(handle, api.session_get_best, "qules_session_get_best");
        detail::load_symbol(handle, api.session_free, "qules_session_free");

        // Julia keeps a pointer to argv, so it must outlive this call.
        static char program_name[] = "qules";
        static char* argv[] = {program_name, nullptr};
        api.init_julia(1, argv);

        detail::g_api = api;
        detail::g_started = true;
    }

    /// Same as the path constructor, from a narrow string such as an `argv`
    /// entry, `getenv` result or string literal. Valid UTF-8 is decoded as
    /// UTF-8; anything else is decoded in the system ANSI code page (what
    /// narrow `argv`/`getenv` deliver unless the executable opts into UTF-8).
    explicit Runtime(std::string_view bundle_dir_utf8)
        : Runtime(std::filesystem::path(detail::narrow_to_wide(bundle_dir_utf8))) {}

    /// Overloads so string literals and `std::string` pick the narrow-string
    /// constructor instead of `std::filesystem::path`'s implicit conversion.
    explicit Runtime(const char* bundle_dir_utf8)
        : Runtime(std::string_view(bundle_dir_utf8)) {}
    explicit Runtime(const std::string& bundle_dir_utf8)
        : Runtime(std::string_view(bundle_dir_utf8)) {}

    ~Runtime() { detail::g_api.shutdown_julia(0); }
    Runtime(const Runtime&) = delete;
    Runtime& operator=(const Runtime&) = delete;
};

/// Minimizes `f` starting from `x0`.
///
/// @param f       Objective; called synchronously on the calling thread. If it
///                throws, the run stops and the exception is rethrown here.
/// @param x0      Start point; must not be empty.
/// @param options Optimizer settings.
/// @return        Best point, its value, evaluation count and final radius.
/// @throws std::invalid_argument for an empty `x0`; qules::Error on a non-zero
///         C status; std::logic_error when no Runtime exists.
inline Result optimize(const Objective& f, std::vector<double> x0, const Options& options = {}) {
    const detail::Api& api = detail::api();
    if (x0.empty()) throw std::invalid_argument("qules: x0 must not be empty");

    Result result;
    result.x_best.assign(x0.size(), 0.0);
    detail::Call call{&f, {}, nullptr};
    int status;
    {
        detail::LogRoute route(options);
        status = api.optimize_c(reinterpret_cast<void*>(&detail::Call::trampoline), x0.size(),
                                x0.data(), options.max_evals, options.delta0, options.delta_min,
                                options.delta_max, options.verbose ? 1 : 0,
                                options.rotation ? 1 : 0, result.x_best.data(), &result.f_best,
                                &result.evals, &result.delta, &call);
        if (call.error) std::rethrow_exception(call.error);
        detail::check(status, "qules_optimize_c");
        route.finish();
    }
    return result;
}

/// Ask/tell driver over the same algorithm as optimize(), for objectives that
/// cannot be wrapped in a callback (external simulators, asynchronous jobs).
///
/// @code
/// qules::Session session({3.0, 1.0}, options);
/// std::vector<double> x;
/// while (session.ask(x)) session.tell(f(x));
/// qules::Result r = session.best();
/// @endcode
///
/// Verbose output is routed to Options::log while the session is open; because
/// that route is process-wide, keep at most one verbose session open at a time.
class Session {
public:
    /// Starts a session from `x0`. @throws like optimize(); qules::Error when
    /// the C side rejects the arguments.
    explicit Session(std::vector<double> x0, const Options& options = {})
        : n_(x0.size()), route_(options) {
        const detail::Api& api = detail::api();
        if (x0.empty()) throw std::invalid_argument("qules: x0 must not be empty");
        std::int64_t id = api.session_create(n_, x0.data(), options.max_evals, options.delta0,
                                             options.delta_min, options.delta_max,
                                             options.verbose ? 1 : 0, options.rotation ? 1 : 0);
        if (id <= 0) {
            throw Error(static_cast<int>(id),
                        "qules: qules_session_create returned " + std::to_string(id));
        }
        id_ = id;
    }
    /// Frees the session if close() was not called.
    ~Session() {
        if (id_ > 0) detail::g_api.session_free(id_);
    }
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    /// Writes the next point to evaluate into `x` and returns true; returns
    /// false once the session has finished.
    bool ask(std::vector<double>& x) {
        x.resize(n_);
        int status = detail::g_api.session_ask(open(), x.data());
        if (status == 1) return true;
        if (status == 0) return false;
        throw Error(status, "qules: qules_session_ask returned " + std::to_string(status));
    }

    /// Reports the objective value of the point returned by the last ask().
    void tell(double f_value) {
        detail::check(detail::g_api.session_tell(open(), f_value), "qules_session_tell");
    }

    /// True once the optimizer has no more points to propose.
    bool finished() const {
        int status = detail::g_api.session_is_finished(open());
        if (status < 0) {
            throw Error(status,
                        "qules: qules_session_is_finished returned " + std::to_string(status));
        }
        return status != 0;
    }

    /// Best point so far; `delta` is NaN until the session has finished.
    /// @throws qules::Error before the first tell().
    Result best() const {
        Result result;
        result.x_best.assign(n_, 0.0);
        detail::check(detail::g_api.session_get_best(open(), result.x_best.data(),
                                                     &result.f_best, &result.evals,
                                                     &result.delta),
                      "qules_session_get_best");
        return result;
    }

    /// Frees the session and delivers pending log output; later calls throw
    /// `std::logic_error`. Idempotent.
    void close() {
        if (id_ <= 0) return;
        int status = detail::g_api.session_free(id_);
        id_ = 0;
        detail::check(status, "qules_session_free");
        route_.finish();
    }

private:
    std::int64_t open() const {
        if (id_ <= 0) throw std::logic_error("qules: session is closed");
        return id_;
    }

    std::size_t n_;
    detail::LogRoute route_;
    std::int64_t id_ = 0;
};

}  // namespace qules
